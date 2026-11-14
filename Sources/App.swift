import SwiftUI
import Photos
import MapKit
import ImageIO

enum CoordinateInterpretation: String, CaseIterable, Identifiable {
 case wgs84 = "WGS-84"
 case gcj02 = "GCJ-02"
 var id: String { rawValue }
 // Interpret stored numbers as WGS-84 for the independent web map.
 // This conversion never modifies the asset.
 func mapCoordinate(_ stored: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
  self == .wgs84 ? stored : Shift.inverse(stored)
 }
 func storedCoordinate(_ map: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
  self == .wgs84 ? map : Shift.forward(map)
 }
 var explanation: String {
  self == .wgs84 ? L("将照片坐标视为 WGS-84，原样交给地图（OpenStreetMap 使用 WGS-84）。切换模式不修改照片。") : L("将照片坐标视为 GCJ-02，转为 WGS-84 后交给地图。切换模式不修改照片。")
 }
}

struct PhotoGroup: Identifiable { let id: String; var assets: [PHAsset] }
struct Album: Identifiable { let id: String; let title: String; let collection: PHAssetCollection }
@MainActor final class Library: ObservableObject {
 @Published var albums: [Album] = []
 @Published var assets: [PHAsset] = []
 @Published var groups: [PhotoGroup] = []
 @Published var listRevision = 0
 @Published var completed = 0
 @Published var total = 0
 @Published var phase = L("准备读取")
 let readOnly = ProcessInfo.processInfo.arguments.contains("--read-only")
 private var loadTask: Task<Void, Never>?
 private var metadataRequest: PHImageRequestID?
 private var metadataContinuation: CheckedContinuation<Bool?, Never>?
 private let previewCache: NSCache<NSString, NSImage> = { let c = NSCache<NSString, NSImage>(); c.totalCostLimit = 80 * 1024 * 1024; c.countLimit = 12; return c }()
 private var previewRequest: PHImageRequestID?
 private let images = PHCachingImageManager()
 private var positions: [String: Int] = [:]
 @Published var selection: Set<String> = []
 @Published var selected: String?
 var selectedAssets: [PHAsset] { selection.compactMap { positions[$0].map { assets[$0] } } }
 func syncSelection() {
  if let selected, selection.contains(selected) { return }
  selected = selection.compactMap { positions[$0] }.min().map { assets[$0].localIdentifier }
 }
 func controlSelect(_ id: String) {
  if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
  selected = selection.contains(id) ? id : selection.compactMap { positions[$0] }.min().map { assets[$0].localIdentifier }
 }
 @Published var album = "all"
 @Published var cameraOnly = false
 @Published var busy = false
 @Published var batchWriting = false
 @Published var message = ""
 @Published var preview: NSImage?
 @Published var provider: MapProvider = .osm
 @Published var appleMainlandInput = true
 @Published var googleKey = UserDefaults.standard.string(forKey: "GoogleMapsAPIKey") ?? "" { didSet { UserDefaults.standard.set(googleKey, forKey: "GoogleMapsAPIKey") } }
 @Published var interpretation: CoordinateInterpretation = .wgs84
 var mapCoordinate: CLLocationCoordinate2D? {
  (mapDraft ?? coordinate).map { stored in
   if provider == .apple && appleMainlandInput {
    return interpretation == .gcj02 ? stored : Shift.forward(stored)
   }
   return interpretation.mapCoordinate(stored)
  }
 }
 func coordinateForSaving(_ map: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
  if provider == .apple && appleMainlandInput {
   return interpretation == .gcj02 ? map : Shift.inverse(map)
  }
  return interpretation.storedCoordinate(map)
 }
 @Published var mapDraft: CLLocationCoordinate2D?
 @Published var coordinate: CLLocationCoordinate2D?
 private var generation = UUID()
 var current: PHAsset? { selected.flatMap { positions[$0] }.map { assets[$0] } }
 func start() async {
  let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
  guard status == .authorized || status == .limited else { message = L("请在系统设置 → 隐私与安全性 → 照片中允许访问。"); return }
  albums = []
  for type in [PHAssetCollectionType.smartAlbum, .album] {
   PHAssetCollection.fetchAssetCollections(with: type, subtype: .any, options: nil).enumerateObjects { c, _, _ in
    self.albums.append(Album(id: c.localIdentifier, title: c.localizedTitle ?? L("未命名相册"), collection: c))
   }
  }
  await reload()
 }
 func cancel() { generation = UUID(); loadTask?.cancel(); if let id = metadataRequest { PHImageManager.default().cancelImageRequest(id) }; metadataRequest = nil; metadataContinuation?.resume(returning: nil); metadataContinuation = nil; busy = false; message = L("已取消加载") }
 func reload() async {
  cancel()
  let token = UUID(); generation = token; busy = true; completed = 0; total = 0; phase = L("正在读取图库索引")
  let started = Date()
  let collection = albums.first(where: { $0.id == album })?.collection
  let filterCamera = cameraOnly
  loadTask = Task {
   let list = await Task.detached(priority: .userInitiated) {
    let options = PHFetchOptions(); options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
    options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
    let result = collection.map { PHAsset.fetchAssets(in: $0, options: options) } ?? PHAsset.fetchAssets(with: options)
    var list: [PHAsset] = []; list.reserveCapacity(result.count)
    for i in 0..<result.count {
     list.append(result.object(at: i))
     if i % 500 == 0 || i == result.count - 1 {
      await MainActor.run { guard self.generation == token else { return }; self.total = result.count; self.completed = i + 1 }
     }
    }
    return list.sorted {
     let a = $0.creationDate ?? .distantPast
     let b = $1.creationDate ?? .distantPast
     return a == b ? $0.localIdentifier < $1.localIdentifier : a > b
    }
   }.value
   guard self.generation == token else { return }
   self.total = list.count; self.completed = 0; self.phase = filterCamera ? L("正在检查拍摄设备（云端原图可能需要下载）") : L("正在建立时间分组")
   var accepted: [PHAsset] = []; var failed = 0
   if filterCamera {
    for (i, a) in list.enumerated() {
     guard self.generation == token, !Task.isCancelled else { return }
     let found = await self.metadata(a)
     guard self.generation == token else { return }
     if found == true { accepted.append(a) }; if found == nil { failed += 1 }
     if i % 10 == 0 || i == list.count - 1 { self.completed = i + 1 }
    }
   } else { accepted = list }
   let final = accepted
   let grouped = await Task.detached(priority: .userInitiated) {
    let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM"
    var groups: [PhotoGroup] = []
    for a in final {
     let key = a.creationDate.map { formatter.string(from: $0) } ?? L("未知日期")
     if groups.last?.id == key { groups[groups.count - 1].assets.append(a) }
     else { groups.append(PhotoGroup(id: key, assets: [a])) }
    }
    return groups
   }.value
   guard self.generation == token else { return }
   self.assets = final; self.groups = grouped; self.listRevision += 1
   self.positions = Dictionary(uniqueKeysWithValues: final.enumerated().map { ($0.element.localIdentifier, $0.offset) })
   self.completed = list.count; self.busy = false
   self.message = L("共 ZZARG0ZZ 张照片；读取失败 ZZARG1ZZ 张", String(final.count), String(failed)) + (self.readOnly ? L(" · 只读测试模式") : "")
   self.selection = Set(final.first.map { [$0.localIdentifier] } ?? [])
   self.selected = final.first?.localIdentifier
   if self.readOnly { print("READ_ONLY_LOAD_COMPLETE total=\(list.count) accepted=\(final.count) failed=\(failed) seconds=\(Date().timeIntervalSince(started))"); fflush(stdout) }
  }
  await loadTask?.value
 }
 func metadata(_ asset: PHAsset) async -> Bool? {
  await withCheckedContinuation { continuation in
   metadataContinuation = continuation
   let token = generation
   let o = PHImageRequestOptions(); o.isNetworkAccessAllowed = true; o.version = .original
   o.progressHandler = { progress, _, _, _ in Task { @MainActor in
    guard self.generation == token else { return }
    self.phase = L("检查拍摄设备 · 当前云端照片下载 ZZARG0ZZ%", String(Int(progress * 100)))
   } }
   metadataRequest = PHImageManager.default().requestImageDataAndOrientation(for: asset, options: o) { data, _, _, _ in
    let found: Bool? = autoreleasepool {
     guard let data, let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary), let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] else { return nil }
     let t = p[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
     return !((t?[kCGImagePropertyTIFFModel as String] as? String) ?? "").isEmpty || !((t?[kCGImagePropertyTIFFMake as String] as? String) ?? "").isEmpty
    }
    Task { @MainActor in
     guard self.generation == token else { return }
     let pending = self.metadataContinuation; self.metadataContinuation = nil; self.metadataRequest = nil
     pending?.resume(returning: found)
    }
   }
  }
 }
 func select() async {
  mapDraft = nil
  if let request = previewRequest { images.cancelImageRequest(request) }
  coordinate = current?.location?.coordinate
  guard let a = current else { preview = nil; return }; let id = a.localIdentifier
  if let cached = previewCache.object(forKey: id as NSString) { preview = cached; return }
  preview = nil
  do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
  guard !Task.isCancelled, selected == id else { return }
  let o = PHImageRequestOptions(); o.isNetworkAccessAllowed = true; o.deliveryMode = .opportunistic; o.resizeMode = .fast
  previewRequest = images.requestImage(for: a, targetSize: CGSize(width: 1400, height: 1000), contentMode: .aspectFit, options: o) { image, _ in
   Task { @MainActor in
    guard self.selected == id else { return }
    self.preview = image
    if let image { self.previewCache.setObject(image, forKey: id as NSString, cost: 1400 * 1000 * 4) }
   }
  }
 }
 func step(_ offset: Int) { guard let i = selected.flatMap({ positions[$0] }), assets.indices.contains(i + offset) else { return }; selected = assets[i + offset].localIdentifier; selection = [assets[i + offset].localIdentifier] }
 func convert(_ forward: Bool) { writeSelected(forward) }
 func applyCoordinateToSelection(_ c: CLLocationCoordinate2D) {
  guard CLLocationCoordinate2DIsValid(c) else { message = L("坐标无效"); return }
  writeSelected(nil, value: c)
 }
 private func writeSelected(_ forward: Bool?, value: CLLocationCoordinate2D? = nil) {
  guard !busy else { return }
  guard !readOnly else { message = L("只读测试模式：已禁止批量写入"); return }
  // Snapshot asset IDs and original values before any asynchronous work.
  let targets = selectedAssets
  let changes = targets.compactMap { asset -> (String, CLLocation)? in
   if let value { return (asset.localIdentifier, CLLocation(latitude: value.latitude, longitude: value.longitude)) }
   guard let original = asset.location, let forward else { return nil }
   let c = forward ? Shift.forward(original.coordinate) : Shift.inverse(original.coordinate)
   return (asset.localIdentifier, CLLocation(latitude: c.latitude, longitude: c.longitude))
  }
  guard !changes.isEmpty else { message = L("选中的照片没有可写入的 GPS 坐标"); return }
  busy = true; batchWriting = true; total = changes.count; completed = 0
  phase = forward.map { $0 ? L("批量写入 WGS-84 → GCJ-02") : L("批量写入 GCJ-02 → WGS-84") } ?? L("批量写入指定坐标")
  Task {
   var succeeded = 0; var failed = 0; var lastError = ""
   for start in stride(from: 0, to: changes.count, by: 100) {
    let batch = Array(changes[start..<min(start + 100, changes.count)])
    let fetched = PHAsset.fetchAssets(withLocalIdentifiers: batch.map { $0.0 }, options: nil)
    var writable: [String: PHAsset] = [:]
    fetched.enumerateObjects { a, _, _ in writable[a.localIdentifier] = a }
    let available = batch.compactMap { id, c -> (PHAsset, CLLocation)? in writable[id].map { ($0, c) } }
    failed += batch.count - available.count
    do {
     try await PHPhotoLibrary.shared().performChanges {
      for (asset, c) in available { PHAssetChangeRequest(for: asset).location = c }
     }
     succeeded += available.count
    } catch { failed += available.count; lastError = error.localizedDescription }
    completed += batch.count
   }
   let refreshed = PHAsset.fetchAssets(withLocalIdentifiers: changes.map { $0.0 }, options: nil)
   var replacements: [String: PHAsset] = [:]
   refreshed.enumerateObjects { a, _, _ in replacements[a.localIdentifier] = a }
   for (id, a) in replacements { if let i = positions[id] { assets[i] = a } }
   await rebuildOrder()
   mapDraft = nil
   coordinate = current?.location?.coordinate
   busy = false; batchWriting = false
   message = L("批量完成：成功 ZZARG0ZZ 张，跳过无 GPS ZZARG1ZZ 张，失败 ZZARG2ZZ 张", String(succeeded), String(targets.count - changes.count), String(failed)) + (lastError.isEmpty ? "" : "；\(lastError)")
  }
 }
 private func rebuildOrder() async {
  let snapshot = assets
  let result = await Task.detached(priority: .userInitiated) {
   let sorted = snapshot.sorted {
    let a = $0.creationDate ?? .distantPast
    let b = $1.creationDate ?? .distantPast
    return a == b ? $0.localIdentifier < $1.localIdentifier : a > b
   }
   let f = DateFormatter(); f.dateFormat = "yyyy-MM"
   var groups: [PhotoGroup] = []
   for asset in sorted {
    let key = asset.creationDate.map { f.string(from: $0) } ?? L("未知日期")
    if groups.last?.id == key { groups[groups.count - 1].assets.append(asset) }
    else { groups.append(PhotoGroup(id: key, assets: [asset])) }
   }
   return (sorted, groups)
  }.value
  assets = result.0; groups = result.1
  positions = Dictionary(uniqueKeysWithValues: assets.enumerated().map { ($0.element.localIdentifier, $0.offset) })
  listRevision += 1
 }
 func save(_ c: CLLocationCoordinate2D) async {
  guard !readOnly else { message = L("只读测试模式：已禁止写入"); return }
  guard let a = current, !busy else { return }; busy = true
  do {
   try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest(for: a).location = CLLocation(latitude: c.latitude, longitude: c.longitude) }
   let refreshed = PHAsset.fetchAssets(withLocalIdentifiers: [a.localIdentifier], options: nil).firstObject
   if let refreshed, let i = assets.firstIndex(where: { $0.localIdentifier == a.localIdentifier }) { assets[i] = refreshed }
   await rebuildOrder()
   if selected == a.localIdentifier { coordinate = refreshed?.location?.coordinate ?? c }
   message = L("已写入照片图库：ZZARG0ZZ, ZZARG1ZZ", String(c.latitude), String(c.longitude))
  } catch { message = L("写入失败：ZZARG0ZZ", String(error.localizedDescription)) }
  busy = false
 }
}
enum Shift {
 static func forward(_ c: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
  let lon = c.longitude, lat = c.latitude
  if lon < 72.004 || lon > 137.8347 || lat < 0.8293 || lat > 55.8271 { return c }
  let x = lon - 105, y = lat - 35, pi = Double.pi
  var a = -100 + 2*x + 3*y + 0.2*y*y + 0.1*x*y + 0.2*sqrt(abs(x))
  a += (20*sin(6*x*pi) + 20*sin(2*x*pi))*2/3
  a += (20*sin(y*pi) + 40*sin(y*pi/3))*2/3
  a += (160*sin(y*pi/12) + 320*sin(y*pi/30))*2/3
  var b = 300 + x + 2*y + 0.1*x*x + 0.1*x*y + 0.1*sqrt(abs(x))
  b += (20*sin(6*x*pi) + 20*sin(2*x*pi))*2/3
  b += (20*sin(x*pi) + 40*sin(x*pi/3))*2/3
  b += (150*sin(x*pi/12) + 300*sin(x*pi/30))*2/3
  let r = lat*pi/180, magic = 1 - 0.00669342162296594323*pow(sin(r), 2)
  a = a*180/((6378245*(1-0.00669342162296594323))/(magic*sqrt(magic))*pi)
  b = b*180/(6378245/sqrt(magic)*cos(r)*pi)
  return CLLocationCoordinate2D(latitude: lat+a, longitude: lon+b)
 }
 static func inverse(_ c: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
  var guess = c
  for _ in 0..<12 { let p = forward(guess); let a = p.latitude-c.latitude, b = p.longitude-c.longitude; guess.latitude -= a; guess.longitude -= b; if abs(a)+abs(b)<1e-9 { break } }
  return guess
 }
}
struct Content: View {
 @ObservedObject var library: Library

 var body: some View {
  VStack(spacing: 0) {
   HStack { Picker(L("相册"), selection: $library.album) { Text(L("所有照片")).tag("all"); ForEach(library.albums) { Text($0.title).tag($0.id) } }.frame(width: 270)
    Toggle(L("仅含拍摄设备信息"), isOn: $library.cameraOnly)
    if library.busy { ProgressView().controlSize(.small) }
    Text(L("按拍摄时间 ↓")).font(.caption).foregroundStyle(.secondary)
    Text(L("已选 ZZARG0ZZ 张", String(library.selection.count))).font(.caption)
    Spacer(); Button("WGS-84 → GCJ-02 (F)") { library.convert(true) }; Button("GCJ-02 → WGS-84 (G)") { library.convert(false) }
   }.padding().disabled(library.busy)
   if library.busy { HStack { VStack(alignment: .leading) { Text(library.phase); if library.total == 0 { ProgressView() } else { ProgressView(value: Double(library.completed), total: Double(max(1, library.total))) }; Text("\(library.completed) / \(library.total)").font(.caption) }; if !library.batchWriting { Button(L("取消")) { library.cancel() } } }.padding(.horizontal).padding(.bottom, 8) }
   HSplitView {
    PhotoList(library: library).frame(minWidth: 260, idealWidth: 320)
    VStack { if let image = library.preview { Image(nsImage: image).resizable().scaledToFit() } else { ContentUnavailableView(L("选择照片"), systemImage: "photo") } }.frame(minWidth: 250, maxWidth: .infinity, maxHeight: .infinity)
    VStack(alignment: .leading, spacing: 8) {
     CoordinateTools(library: library)
     Picker(L("地图来源"), selection: $library.provider) {
      ForEach(MapProvider.allCases) { Text($0.rawValue).tag($0) }
     }.padding(.horizontal, 8)
     if library.provider == .apple {
      Picker(L("Apple 地图输入"), selection: $library.appleMainlandInput) {
       Text(L("大陆 GCJ-02 输入")).tag(true)
       Text(L("WGS-84 原样输入")).tag(false)
      }.padding(.horizontal, 8)
      Text(library.appleMainlandInput ? L("大陆显示适配：WGS-84 照片正向转换一次；GCJ-02 照片原样传入。仅影响显示，拖针保存时反向换算。") : L("原样 WGS-84 输入：适合接受 WGS-84 的 Apple 地图环境。"))
       .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8)
     }
     if library.provider == .google {
      SecureField("Google Maps JavaScript API Key", text: $library.googleKey).textFieldStyle(.roundedBorder).padding(.horizontal, 8)
      Text(L("Google 中国大陆道路与影像可能存在坐标差异；优先使用 OpenStreetMap 对照原始 GPS。配置 Key 后地图位置会发送给所选地图服务。"))
       .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8)
     }
     Picker(L("照片坐标解释"), selection: $library.interpretation) {
      ForEach(CoordinateInterpretation.allCases) { mode in Text(L("按 ZZARG0ZZ 解释", String(mode.rawValue))).tag(mode) }
     }.pickerStyle(.segmented).padding(.horizontal, 8)
     Text(library.provider == .apple && library.appleMainlandInput ? L("照片坐标解释用于指定原值的坐标系；地图按大陆 GCJ-02 接收。切换不修改照片。") : library.interpretation.explanation).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8)
     if library.provider == .google && library.googleKey.isEmpty {
      VStack(spacing: 12) {
       Text(L("内嵌 Google 地图需要 API Key"))
       Text(L("请启用 Maps JavaScript API 并填写 Key；也可以在浏览器中对照。 ")).font(.caption)
       if let c = library.mapCoordinate, let url = URL(string: "https://www.google.com/maps/search/?api=1&query=\(c.latitude),\(c.longitude)") { Link(L("在 Google 地图中打开"), destination: url) }
      }.frame(maxWidth: .infinity, maxHeight: .infinity).padding()
     } else if library.provider == .apple {
      ApplePhotoMap(coordinate: library.mapCoordinate, editable: !library.readOnly && !library.busy && library.current != nil) { c in
       let stored = library.coordinateForSaving(c)
       library.applyCoordinateToSelection(stored)
      }
     } else {
     WebPhotoMap(provider: library.provider, apiKey: library.googleKey, coordinate: library.mapCoordinate, editable: !library.readOnly && !library.busy && library.current != nil) { c in
      let stored = library.coordinateForSaving(c)
      library.applyCoordinateToSelection(stored)
     }
     }
     Group {
      Text(library.coordinate.map { String(format: L("照片原值：%.7f, %.7f"), $0.latitude, $0.longitude) } ?? L("无 GPS；双击地图放置大头针"))
      Text(library.mapCoordinate.map { String(format: L("地图输入坐标：%.7f, %.7f"), $0.latitude, $0.longitude) } ?? L("地图输入：—"))
     }.font(.caption).monospacedDigit().textSelection(.enabled).padding(.horizontal, 8)
     Text(L("Shift 连选，Command/Ctrl 增减选择；地图设置及粘贴坐标应用到所有选中照片。"))
      .font(.caption).foregroundStyle(.secondary).padding([.horizontal, .bottom], 8)
    }.frame(minWidth: 360, idealWidth: 440)
   }
   if library.readOnly { Text(L("只读测试模式 · 已禁止所有照片写入")).foregroundStyle(.orange) }
   Button(L("重新读取图库 / 重试授权")) { Task { await library.start() } }.disabled(library.busy)
   Text(library.message).font(.caption).frame(maxWidth: .infinity, alignment: .leading).padding(8)
  }.frame(minWidth: 1100, minHeight: 650)
  .task { await library.start() }.task(id: library.selected) { await library.select() }
  .onChange(of: library.selection) { library.syncSelection() }
  .onChange(of: library.album) { Task { await library.reload() } }.onChange(of: library.cameraOnly) { Task { await library.reload() } }
 }
}
@main struct PhotoCoordinatesApp: App {
 @StateObject var library = Library()
 var body: some Scene { WindowGroup { Content(library: library) }.commands {
  CommandMenu(L("照片坐标")) {
   Button("WGS-84 → GCJ-02") { library.convert(true) }.keyboardShortcut("f", modifiers: []).disabled(library.selection.isEmpty || library.busy || library.readOnly)
   Button("GCJ-02 → WGS-84") { library.convert(false) }.keyboardShortcut("g", modifiers: []).disabled(library.selection.isEmpty || library.busy || library.readOnly)
   Button(L("复制照片坐标")) { library.copyCoordinate() }.keyboardShortcut("c", modifiers: [.command, .shift])
   Button(L("粘贴坐标到所选照片")) { library.pasteCoordinate() }.keyboardShortcut("v", modifiers: [.command, .shift]).disabled(library.busy || library.readOnly || library.selection.isEmpty)
   Divider()
   Picker(L("照片坐标解释（仅显示）"), selection: $library.interpretation) {
    ForEach(CoordinateInterpretation.allCases) { mode in Text(L("按 ZZARG0ZZ 解释", String(mode.rawValue))).tag(mode) }
   }
   Divider()
   Button(L("上一张")) { library.step(-1) }.keyboardShortcut(.leftArrow, modifiers: [])
   Button(L("下一张")) { library.step(1) }.keyboardShortcut(.rightArrow, modifiers: [])
  }
 } }
}
