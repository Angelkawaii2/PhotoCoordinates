import SwiftUI
import Photos
import AppKit

struct PhotoList: NSViewRepresentable {
 @ObservedObject var library: Library
 func makeCoordinator() -> Coordinator { Coordinator(library) }
 func makeNSView(context: Context) -> NSScrollView {
  let table = FastTable(); table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("photo")))
  table.headerView = nil; table.allowsMultipleSelection = true; table.rowHeight = 92
  table.delegate = context.coordinator; table.dataSource = context.coordinator
  table.contextMenuHandler = { [weak coordinator = context.coordinator] row in coordinator?.contextMenu(for: row) }
  context.coordinator.table = table
  let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.documentView = table
  return scroll
 }
 func updateNSView(_ scroll: NSScrollView, context: Context) {
  let c = context.coordinator; c.library = library
  guard let table = c.table else { return }
  c.updating = true; defer { c.updating = false }
  let dataChanged = c.revision != library.listRevision
  let scrollOrigin = scroll.contentView.bounds.origin
  if dataChanged {
   c.revision = library.listRevision; c.rows = []; c.indices = [:]
   for group in library.groups {
    c.rows.append(.header(group.id))
    for asset in group.assets { c.indices[asset.localIdentifier] = c.rows.count; c.rows.append(.asset(asset)) }
   }
   table.reloadData()
  }
  if dataChanged || c.lastSelection != library.selection {
   c.lastSelection = library.selection
   let indices = IndexSet(library.selection.compactMap { c.indices[$0] })
   table.selectRowIndexes(indices, byExtendingSelection: false)
  }
  if dataChanged { scroll.contentView.scroll(to: scrollOrigin); scroll.reflectScrolledClipView(scroll.contentView) }
 }
 final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
  enum Row { case header(String), asset(PHAsset) }
  var library: Library; weak var table: NSTableView?
  var rows: [Row] = []; var indices: [String: Int] = [:]; var revision = -1
  var updating = false; var lastSelection: Set<String> = []
  let formatter: DateFormatter = { let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f }()
  init(_ library: Library) { self.library = library }
  @MainActor func contextMenu(for row: Int) -> NSMenu? {
   guard rows.indices.contains(row), case .asset(let asset) = rows[row], let table else { return nil }
   if !table.selectedRowIndexes.contains(row) {
    table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
   }
   let menu = NSMenu()
   let copy = NSMenuItem(title: L("复制此照片坐标"), action: #selector(copyCoordinate(_:)), keyEquivalent: "")
   copy.target = self; copy.representedObject = asset; copy.isEnabled = asset.location != nil
   menu.addItem(copy)
   let paste = NSMenuItem(title: L("粘贴坐标到所选照片（ZZARG0ZZ 张）", String(library.selection.count)), action: #selector(pasteCoordinates(_:)), keyEquivalent: "")
   paste.target = self
   paste.isEnabled = !library.busy && !library.readOnly && !library.selection.isEmpty && NSPasteboard.general.string(forType: .string).flatMap(CoordinateText.parse) != nil
   menu.addItem(paste)
   return menu
  }
  @MainActor @objc private func copyCoordinate(_ sender: NSMenuItem) { library.copyCoordinate(of: sender.representedObject as? PHAsset) }
  @MainActor @objc private func pasteCoordinates(_ sender: NSMenuItem) { library.pasteCoordinate() }
  func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
  func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { if case .asset = rows[row] { return true }; return false }
  func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { if case .header = rows[row] { return true }; return false }
  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
   switch rows[row] {
   case .header(let title):
    let id = NSUserInterfaceItemIdentifier("header")
    let v = tableView.makeView(withIdentifier: id, owner: nil) as? NSTextField ?? NSTextField(labelWithString: "")
    v.identifier = id; v.stringValue = title; v.font = .boldSystemFont(ofSize: 12); return v
   case .asset(let asset):
    let id = NSUserInterfaceItemIdentifier("cell")
    let cell = tableView.makeView(withIdentifier: id, owner: nil) as? PhotoCell ?? PhotoCell()
    cell.identifier = id
    cell.configure(asset, title: asset.creationDate.map { formatter.string(from: $0) } ?? L("未知时间"))
    return cell
   }
  }
  func tableViewSelectionDidChange(_ notification: Notification) {
   guard !updating, let table else { return }
   let ids = Set(table.selectedRowIndexes.compactMap { i -> String? in if case .asset(let a) = rows[i] { return a.localIdentifier }; return nil })
   lastSelection = ids; library.selection = ids
   if case .asset(let a) = rows.indices.contains(table.selectedRow) ? rows[table.selectedRow] : .header("") { library.selected = a.localIdentifier }
   else { library.selected = nil }
  }
 }
}
final class FastTable: NSTableView {
 var contextMenuHandler: (@MainActor (Int) -> NSMenu?)?
 override func menu(for event: NSEvent) -> NSMenu? {
  contextMenuHandler?(row(at: convert(event.locationInWindow, from: nil)))
 }
 override func mouseDown(with event: NSEvent) {
  if event.modifierFlags.contains(.control) {
   let row = row(at: convert(event.locationInWindow, from: nil))
   guard row >= 0, delegate?.tableView?(self, shouldSelectRow: row) != false else { return }
   if selectedRowIndexes.contains(row) { deselectRow(row) } else { selectRowIndexes(IndexSet(integer: row), byExtendingSelection: true) }
   return
  }
  super.mouseDown(with: event)
 }
}
final class PhotoCell: NSTableCellView {
 private let thumb = NSImageView(frame: NSRect(x: 4, y: 36, width: 64, height: 48))
 private let label = NSTextField(labelWithString: "")
 private let filename = NSTextField(labelWithString: "")
 private static let filenameCache = NSCache<NSString, NSString>()
 private let gpsTag = NSImageView()
 private let storage = NSImageView()
 private var storageRequest: PHContentEditingInputRequestID?
 private var storageAsset: PHAsset?
 private var request: PHImageRequestID?
 private var assetID = ""
 override init(frame frameRect: NSRect) {
  super.init(frame: frameRect); thumb.imageScaling = .scaleProportionallyUpOrDown; addSubview(thumb)
  filename.font = .systemFont(ofSize: 12, weight: .medium); filename.lineBreakMode = .byTruncatingMiddle; filename.maximumNumberOfLines = 1
  addSubview(filename)
  label.font = .systemFont(ofSize: 11); label.textColor = .secondaryLabelColor; label.maximumNumberOfLines = 1; label.lineBreakMode = .byTruncatingTail; addSubview(label)
  addSubview(gpsTag)
  storage.contentTintColor = .systemBlue; addSubview(storage)

 }
 override func layout() {
  super.layout()
  let rightWidth = max(0, bounds.width - 86)
  thumb.frame = NSRect(x: 6, y: 22, width: 64, height: 52)
  filename.frame = NSRect(x: 82, y: 64, width: rightWidth, height: 18)
  label.frame = NSRect(x: 82, y: 41, width: rightWidth, height: 17)
  gpsTag.frame = NSRect(x: 82, y: 13, width: 19, height: 19)
  storage.frame = NSRect(x: 110, y: 13, width: 21, height: 19)
 }
 required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
 func configure(_ asset: PHAsset, title: String) {
  label.stringValue = L("拍摄：") + title
  label.toolTip = label.stringValue
  let key = asset.localIdentifier as NSString
  let name: String
  if let cached = Self.filenameCache.object(forKey: key) { name = cached as String }
  else {
   let resources = PHAssetResource.assetResources(for: asset)
   name = (resources.first { $0.type == .photo } ?? resources.first { $0.type == .fullSizePhoto } ?? resources.first)?.originalFilename ?? L("未知文件名")
   Self.filenameCache.countLimit = 2000
   Self.filenameCache.setObject(name as NSString, forKey: key)
  }
  filename.stringValue = name; filename.toolTip = name
  let hasGPS = asset.location != nil
  gpsTag.image = NSImage(systemSymbolName: hasGPS ? "globe" : "mappin", accessibilityDescription: hasGPS ? L("有 GPS") : L("无 GPS"))
  gpsTag.contentTintColor = hasGPS ? .systemGreen : .systemRed
  gpsTag.toolTip = hasGPS ? L("有 GPS") : L("无 GPS")
  guard assetID != asset.localIdentifier else { return }
  cancel(); assetID = asset.localIdentifier; thumb.image = nil
  let id = assetID
  storage.image = nil; storage.toolTip = L("检查本地状态"); storageAsset = asset
  let localOptions = PHContentEditingInputRequestOptions(); localOptions.isNetworkAccessAllowed = false
  storageRequest = asset.requestContentEditingInput(with: localOptions) { [weak self] input, info in
   let cloud = (info[PHContentEditingInputResultIsInCloudKey] as? NSNumber)?.boolValue == true
   let text: String
   if input?.fullSizeImageURL != nil { text = L("本地全尺寸图像可用") }
   else if cloud { text = L("iCloud · 需下载全尺寸图像") }
   else { text = L("本地状态未知") }
   DispatchQueue.main.async { guard let self, self.assetID == id else { return }; self.storage.image = cloud ? NSImage(systemSymbolName: "icloud", accessibilityDescription: "iCloud") : nil; self.storage.toolTip = text }
  }
  let options = PHImageRequestOptions(); options.isNetworkAccessAllowed = false; options.deliveryMode = .fastFormat; options.resizeMode = .fast
  request = PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 128, height: 96), contentMode: .aspectFit, options: options) { [weak self] image, _ in
   DispatchQueue.main.async { guard let self, self.assetID == id else { return }; self.thumb.image = image }
  }
 }
 private func cancel() { if let storageRequest { storageAsset?.cancelContentEditingInputRequest(storageRequest) }; storageRequest = nil; storageAsset = nil; if let request { PHImageManager.default().cancelImageRequest(request) }; request = nil }
 override func prepareForReuse() { super.prepareForReuse(); cancel(); assetID = ""; thumb.image = nil }
}
