import SwiftUI
import WebKit
import CoreLocation

enum MapProvider: String, CaseIterable, Identifiable {
 case apple = "Apple", osm = "OpenStreetMap", google = "Google"
 var id: String { rawValue }
}
struct WebPhotoMap: NSViewRepresentable {
 let provider: MapProvider
 let apiKey: String
 let coordinate: CLLocationCoordinate2D?
 let editable: Bool
 let save: (CLLocationCoordinate2D) -> Void
 func makeCoordinator() -> Coordinator { Coordinator(self) }
 func makeNSView(context: Context) -> WKWebView {
  let config = WKWebViewConfiguration()
  config.userContentController.add(context.coordinator, name: "position")
  let view = WKWebView(frame: .zero, configuration: config)
  view.customUserAgent = "PhotoCoordinates/1.0 macOS (interactive photo location viewer)"
  view.navigationDelegate = context.coordinator
  return view
 }
 func updateNSView(_ view: WKWebView, context: Context) {
  context.coordinator.parent = self
  let identity = provider.rawValue + apiKey
  if context.coordinator.identity != identity {
   context.coordinator.identity = identity; context.coordinator.ready = false
   view.loadHTMLString(html, baseURL: URL(string: "https://localhost/"))
  } else if context.coordinator.ready { context.coordinator.update(view) }
 }
 static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
  view.configuration.userContentController.removeScriptMessageHandler(forName: "position")
  view.stopLoading()
 }
 var html: String {
  let key = apiKey.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
  let engine: String
  if provider == .osm {
   engine = """
   <link rel="stylesheet" href="https://unpkg.com/leaflet@1.9.4/dist/leaflet.css">
   <script src="https://unpkg.com/leaflet@1.9.4/dist/leaflet.js"></script>
   <script>
   let map=L.map('map',{doubleClickZoom:false}).setView([30,110],4), pin=null;
   L.tileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png',{maxZoom:19,attribution:'&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap contributors</a>'}).addTo(map);
   function place(lat,lon,editable){if(pin)map.removeLayer(pin);pin=L.marker([lat,lon],{draggable:editable}).addTo(map);pin.on('dragend',()=>{let p=pin.getLatLng();send(p.lat,p.lng)});}
   window.applyPosition=(lat,lon,editable)=>{window.canEdit=editable;if(lat===null){if(pin)map.removeLayer(pin);pin=null;return;}place(lat,lon,editable);map.setView([lat,lon],16);};
   map.on('dblclick',e=>{if(window.canEdit){place(e.latlng.lat,e.latlng.lng,true);send(e.latlng.lat,e.latlng.lng)}});
   ready();
   </script>
   """
  } else {
   engine = """
   <script>
   let map,pin=null;
   window.initMap=()=>{map=new google.maps.Map(document.getElementById('map'),{center:{lat:30,lng:110},zoom:4,disableDoubleClickZoom:true});
   map.addListener('dblclick',e=>{if(window.canEdit){place(e.latLng.lat(),e.latLng.lng(),true);send(e.latLng.lat(),e.latLng.lng())}});ready();};
   function place(lat,lng,editable){if(pin)pin.setMap(null);pin=new google.maps.Marker({position:{lat,lng},map,draggable:editable});pin.addListener('dragend',e=>send(e.latLng.lat(),e.latLng.lng()));}
   window.applyPosition=(lat,lng,editable)=>{window.canEdit=editable;if(lat===null){if(pin)pin.setMap(null);pin=null;return;}place(lat,lng,editable);map.setCenter({lat,lng});map.setZoom(16);};
   window.gm_authFailure=()=>{document.getElementById('status').innerText='Google 地图授权失败，请检查 API Key、API 启用状态与限制。'};
   </script>
   <script async src="https://maps.googleapis.com/maps/api/js?key=\(key)&callback=initMap"></script>
   """
  }
  return """
  <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"><style>html,body,#map{height:100%;margin:0}#status{position:absolute;top:8px;left:8px;z-index:1000;background:white;color:#333;padding:6px;font:13px sans-serif}</style></head><body><div id="map"></div><div id="status">正在加载地图；若长时间空白，请检查网络。</div><script>
  function send(lat,lon){window.webkit.messageHandlers.position.postMessage({lat,lon});}
  function ready(){document.getElementById('status').style.display='none';window.webkit.messageHandlers.position.postMessage({ready:true});}
  </script>\(engine)</body></html>
  """
 }
 class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
  var parent: WebPhotoMap; var identity = ""; var ready = false; var last = ""
  init(_ parent: WebPhotoMap) { self.parent = parent }
  func update(_ view: WKWebView) {
   let c = parent.coordinate
   let script = "window.applyPosition(\(c.map { String($0.latitude) } ?? "null"),\(c.map { String($0.longitude) } ?? "null"),\(parent.editable ? "true" : "false"));"
   guard script != last else { return }; last = script
   view.evaluateJavaScript(script, completionHandler: nil)
  }
  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
   guard let body = message.body as? [String: Any] else { return }
   if body["ready"] as? Bool == true { ready = true; last = ""; if let view = message.webView { update(view) }; return }
   guard parent.editable, let lat = body["lat"] as? Double, let lon = body["lon"] as? Double else { return }
   let c = CLLocationCoordinate2D(latitude: lat, longitude: lon)
   guard CLLocationCoordinate2DIsValid(c) else { return }; parent.save(c)
  }
 }
}
