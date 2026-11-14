import Foundation

// English is the development language and fallback for unsupported system languages.
private let localizedBundle: Bundle = {
 let supported = ["en", "ja", "fr", "de", "zh-Hans"]
 let preferred = Bundle.preferredLocalizations(from: supported, forPreferences: Locale.preferredLanguages).first ?? "en"
 let path = Bundle.main.path(forResource: preferred, ofType: "lproj") ?? Bundle.main.path(forResource: "en", ofType: "lproj")
 return path.flatMap(Bundle.init(path:)) ?? Bundle.main
}()
func L(_ key: String, _ arguments: String...) -> String {
 var text = localizedBundle.localizedString(forKey: key, value: key, table: nil)
 for (index, value) in arguments.enumerated() { text = text.replacingOccurrences(of: "ZZARG\(index)ZZ", with: value) }
 return text
}
