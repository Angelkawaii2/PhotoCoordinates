import SwiftUI
import MapKit
import AppKit
import Photos

enum CoordinateText {
 static func parse(_ text: String) -> CLLocationCoordinate2D? {
  let parts = text.replacingOccurrences(of: "，", with: ",").split { $0 == "," || $0.isWhitespace }.map(String.init)
  guard parts.count == 2, let lat = Double(parts[0]), let lon = Double(parts[1]), lat.isFinite, lon.isFinite else { return nil }
  let c = CLLocationCoordinate2D(latitude: lat, longitude: lon)
  return CLLocationCoordinate2DIsValid(c) ? c : nil
 }
 static func format(_ c: CLLocationCoordinate2D) -> String { String(format: "%.8f, %.8f", locale: Locale(identifier: "en_US_POSIX"), c.latitude, c.longitude) }
}
extension Library {
 func copyCoordinate(of asset: PHAsset? = nil) {
  guard let coordinate = (asset ?? current)?.location?.coordinate else { message = L("该照片没有坐标"); return }
  NSPasteboard.general.clearContents(); NSPasteboard.general.setString(CoordinateText.format(coordinate), forType: .string)
  message = L("已复制照片原始坐标")
 }
 func pasteCoordinate() {
  guard let text = NSPasteboard.general.string(forType: .string), let c = CoordinateText.parse(text) else { message = L("剪贴板格式应为：纬度, 经度"); return }
  applyCoordinateToSelection(c)
 }
}
@MainActor final class PlaceSearch: ObservableObject {
 @Published var query = ""
 @Published var results: [MKMapItem] = []
 @Published var busy = false
 @Published var error = ""
 private var search: MKLocalSearch?
 private var token = UUID()
 func run() {
  search?.cancel(); token = UUID(); let id = token
  let text = query.trimmingCharacters(in: .whitespacesAndNewlines); guard !text.isEmpty else { return }
  let request = MKLocalSearch.Request(); request.naturalLanguageQuery = text; request.resultTypes = [.address, .pointOfInterest]
  let operation = MKLocalSearch(request: request); search = operation; busy = true; error = ""
  Task {
   do { let response = try await operation.start(); guard token == id else { return }; results = Array(response.mapItems.prefix(5)); if results.isEmpty { error = L("未找到地点") } }
   catch { guard token == id else { return }; self.error = error.localizedDescription }
   guard token == id else { return }; busy = false; search = nil
  }
 }
 func cancel() { search?.cancel(); token = UUID(); busy = false }
}
struct CoordinateTools: View {
 @ObservedObject var library: Library
 @StateObject private var search = PlaceSearch()
 @StateObject private var entry = CoordinateEntry()
 var body: some View {
  VStack(spacing: 6) {
   HStack {
    TextField(L("搜索地点"), text: $search.query).onSubmit { search.run() }
    Button { search.run() } label: { Image(systemName: "magnifyingglass") }.disabled(search.busy).help(L("搜索地点"))
    if search.busy { ProgressView().controlSize(.small) }
   }
   ForEach(Array(search.results.enumerated()), id: \.offset) { _, item in
    Button(item.name ?? L("地点")) {
     // Search coordinates follow MapKit's regional input convention. Match
     // the user's verified Apple input setting before projecting to providers.
     let raw = item.placemark.coordinate
     let wgs = library.appleMainlandInput ? Shift.inverse(raw) : raw
     let stored = library.interpretation == .gcj02 ? Shift.forward(wgs) : wgs
     library.mapDraft = stored; entry.text = CoordinateText.format(stored)
    }.buttonStyle(.link).frame(maxWidth: .infinity, alignment: .leading)
   }
   if !search.error.isEmpty { Text(search.error).font(.caption).foregroundStyle(.secondary) }
   HStack {
    TextField(L("纬度, 经度"), text: $entry.text)
    Button { library.copyCoordinate() } label: { Image(systemName: "doc.on.doc") }.help(L("复制照片原始坐标 · ⌘⇧C"))
    Button {
     if let text = NSPasteboard.general.string(forType: .string), let c = CoordinateText.parse(text) { entry.text = CoordinateText.format(c); library.mapDraft = c }
     else { library.message = L("剪贴板格式应为：纬度, 经度") }
    } label: { Image(systemName: "doc.on.clipboard") }.help(L("粘贴坐标并预览"))
    Button {
     guard let c = CoordinateText.parse(entry.text) else { library.message = L("请输入有效的纬度, 经度"); return }
     library.applyCoordinateToSelection(c)
    } label: { Image(systemName: "mappin.and.ellipse") }.disabled(library.busy || library.readOnly || library.selection.isEmpty).help(L("将此坐标直接写入所有选中照片"))
   }
  }.textFieldStyle(.roundedBorder).padding(.horizontal, 8).onDisappear { search.cancel() }
 }
}
@MainActor final class CoordinateEntry: ObservableObject { @Published var text = "" }
