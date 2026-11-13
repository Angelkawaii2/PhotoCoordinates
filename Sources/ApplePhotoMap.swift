import SwiftUI
import MapKit

struct ApplePhotoMap: NSViewRepresentable {
 let coordinate: CLLocationCoordinate2D?
 let editable: Bool
 let save: (CLLocationCoordinate2D) -> Void
 func makeCoordinator() -> Coordinator { Coordinator(self) }
 func makeNSView(context: Context) -> MKMapView {
  let map = MKMapView()
  map.delegate = context.coordinator
  let click = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.place(_:)))
  click.numberOfClicksRequired = 2
  map.addGestureRecognizer(click)
  return map
 }
 func updateNSView(_ map: MKMapView, context: Context) {
  let coordinator = context.coordinator
  coordinator.parent = self
  guard let c = coordinate else {
   map.removeAnnotations(map.annotations); coordinator.last = nil; return
  }
  if let last = coordinator.last,
     abs(last.latitude - c.latitude) + abs(last.longitude - c.longitude) < 1e-10 {
   for annotation in map.annotations { map.view(for: annotation)?.isDraggable = editable }
   return
  }
  coordinator.last = c
  map.removeAnnotations(map.annotations)
  let pin = MKPointAnnotation(); pin.coordinate = c
  map.addAnnotation(pin)
  map.setRegion(MKCoordinateRegion(center: c, latitudinalMeters: 1800, longitudinalMeters: 1800), animated: true)
 }
 static func dismantleNSView(_ map: MKMapView, coordinator: Coordinator) { map.delegate = nil }
 class Coordinator: NSObject, MKMapViewDelegate {
  var parent: ApplePhotoMap
  var last: CLLocationCoordinate2D?
  init(_ parent: ApplePhotoMap) { self.parent = parent }
  @objc func place(_ gesture: NSClickGestureRecognizer) {
   guard parent.editable, let map = gesture.view as? MKMapView else { return }
   let c = map.convert(gesture.location(in: map), toCoordinateFrom: map)
   guard CLLocationCoordinate2DIsValid(c) else { return }; parent.save(c)
  }
  func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
   let view = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: nil)
   view.isDraggable = parent.editable
   return view
  }
  func mapView(_ mapView: MKMapView, annotationView view: MKAnnotationView,
               didChange newState: MKAnnotationView.DragState, fromOldState oldState: MKAnnotationView.DragState) {
   guard newState == .ending else { return }
   defer { view.dragState = .none }
   guard parent.editable, let c = view.annotation?.coordinate, CLLocationCoordinate2DIsValid(c) else { return }
   parent.save(c)
  }
 }
}
