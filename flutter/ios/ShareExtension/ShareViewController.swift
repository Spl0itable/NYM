import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
  private static let group = "group.com.nym.bar"
  private static let inboxFolder = "ShareInbox"
  private static let manifestName = "manifest.json"
  private static let maxFiles = 10
  private static let maxFileBytes = 16 * 1024 * 1024
  private static let maxTotalBytes = 64 * 1024 * 1024
  private static let maxTextLength = 100_000

  private let lock = NSLock()
  private var inbox: URL?
  private var texts: [String] = []
  private var files: [[String: Any]] = []
  private var totalBytes = 0
  private var full = false
  private var started = false

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    let spinner = UIActivityIndicatorView(style: .large)
    spinner.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(spinner)
    NSLayoutConstraint.activate([
      spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
    ])
    spinner.startAnimating()
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    guard !started else { return }
    started = true
    let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
    let providers = items.flatMap { $0.attachments ?? [] }
    let captions = items.compactMap { $0.attributedContentText?.string }
    DispatchQueue.global(qos: .userInitiated).async {
      guard self.prepareInbox() else {
        DispatchQueue.main.async { self.cancel() }
        return
      }
      self.load(providers, at: 0) {
        var saved = false
        self.locked {
          if self.texts.isEmpty {
            captions.forEach { self.addText($0) }
          }
          saved = self.writeManifest()
        }
        DispatchQueue.main.async { self.finish(opening: saved) }
      }
    }
  }

  private func locked(_ body: () -> Void) {
    lock.lock()
    body()
    lock.unlock()
  }

  private func prepareInbox() -> Bool {
    let manager = FileManager.default
    guard
      let container = manager.containerURL(forSecurityApplicationGroupIdentifier: Self.group)
    else { return false }
    let folder = container
      .appendingPathComponent(Self.inboxFolder, isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    do {
      try manager.createDirectory(at: folder, withIntermediateDirectories: true)
    } catch {
      return false
    }
    locked { inbox = folder }
    return true
  }

  private func load(_ providers: [NSItemProvider], at index: Int, done: @escaping () -> Void) {
    guard index < providers.count else {
      done()
      return
    }
    loadOne(providers[index]) {
      self.load(providers, at: index + 1, done: done)
    }
  }

  private func loadOne(_ provider: NSItemProvider, next: @escaping () -> Void) {
    let types = provider.registeredTypeIdentifiers.compactMap { UTType($0) }
    if let media = types.first(where: { $0.conforms(to: .image) || $0.conforms(to: .audiovisualContent) }) {
      loadFile(provider, type: media, next: next)
    } else if types.contains(where: { $0.conforms(to: .url) && !$0.conforms(to: .fileURL) }) {
      loadItem(provider, type: .url, next: next)
    } else if types.contains(where: { $0.conforms(to: .fileURL) }) {
      loadItem(provider, type: .fileURL, next: next)
    } else if types.contains(where: { $0.conforms(to: .plainText) }) {
      loadItem(provider, type: .plainText, next: next)
    } else if let data = types.first(where: { $0.conforms(to: .data) }) {
      loadFile(provider, type: data, next: next)
    } else {
      next()
    }
  }

  private func loadItem(_ provider: NSItemProvider, type: UTType, next: @escaping () -> Void) {
    provider.loadItem(forTypeIdentifier: type.identifier, options: nil) { item, _ in
      self.locked { self.handle(item, provider: provider, type: type) }
      next()
    }
  }

  private func loadFile(_ provider: NSItemProvider, type: UTType, next: @escaping () -> Void) {
    provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
      if let url = url {
        self.locked {
          self.storeFile(at: url, name: provider.suggestedName ?? url.lastPathComponent, type: type)
        }
        next()
        return
      }
      provider.loadItem(forTypeIdentifier: type.identifier, options: nil) { item, _ in
        self.locked { self.handle(item, provider: provider, type: type) }
        next()
      }
    }
  }

  private func handle(_ item: NSSecureCoding?, provider: NSItemProvider, type: UTType) {
    guard let item = item else { return }
    if let url = item as? URL {
      if url.isFileURL {
        let fileType = UTType(filenameExtension: url.pathExtension) ?? type
        storeFile(at: url, name: provider.suggestedName ?? url.lastPathComponent, type: fileType)
      } else {
        addText(url.absoluteString)
      }
    } else if let text = item as? String {
      addText(text)
    } else if let text = item as? NSAttributedString {
      addText(text.string)
    } else if let image = item as? UIImage {
      if let data = image.pngData() {
        storeData(data, name: provider.suggestedName, type: .png)
      }
    } else if let data = item as? Data {
      if type.conforms(to: .url), let url = URL(dataRepresentation: data, relativeTo: nil) {
        handle(url as NSURL, provider: provider, type: type)
      } else if type.conforms(to: .text), let text = String(data: data, encoding: .utf8) {
        addText(text)
      } else {
        storeData(data, name: provider.suggestedName, type: type)
      }
    }
  }

  private func addText(_ raw: String) {
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, !texts.contains(text) else { return }
    texts.append(text)
  }

  private func accepts(_ size: Int) -> Bool {
    guard !full, files.count < Self.maxFiles, size > 0, size <= Self.maxFileBytes else {
      return false
    }
    if totalBytes + size > Self.maxTotalBytes {
      full = true
      return false
    }
    return true
  }

  private func storeFile(at source: URL, name: String?, type: UTType?) {
    guard let inbox = inbox else { return }
    let scoped = source.startAccessingSecurityScopedResource()
    defer {
      if scoped { source.stopAccessingSecurityScopedResource() }
    }
    guard
      let values = try? source.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
      values.isRegularFile == true,
      let size = values.fileSize,
      accepts(size)
    else { return }
    let stored = UUID().uuidString
    let target = inbox.appendingPathComponent(stored, isDirectory: false)
    do {
      try FileManager.default.copyItem(at: source, to: target)
    } catch {
      return
    }
    let copied = (try? target.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
    guard copied == size else {
      try? FileManager.default.removeItem(at: target)
      return
    }
    record(stored: stored, size: size, name: name, type: type)
  }

  private func storeData(_ data: Data, name: String?, type: UTType?) {
    guard let inbox = inbox, accepts(data.count) else { return }
    let stored = UUID().uuidString
    let target = inbox.appendingPathComponent(stored, isDirectory: false)
    do {
      try data.write(to: target)
    } catch {
      return
    }
    record(stored: stored, size: data.count, name: name, type: type)
  }

  private func record(stored: String, size: Int, name: String?, type: UTType?) {
    totalBytes += size
    var entry: [String: Any] = [
      "name": Self.displayName(name, type: type),
      "file": stored,
    ]
    if let mime = type?.preferredMIMEType {
      entry["mime"] = mime
    }
    files.append(entry)
  }

  private func writeManifest() -> Bool {
    guard let inbox = inbox else { return false }
    let text = String(texts.joined(separator: "\n").prefix(Self.maxTextLength))
    guard !text.isEmpty || !files.isEmpty else {
      try? FileManager.default.removeItem(at: inbox)
      return false
    }
    var manifest: [String: Any] = [
      "created": Date().timeIntervalSince1970,
      "files": files,
    ]
    if !text.isEmpty {
      manifest["text"] = text
    }
    do {
      let data = try JSONSerialization.data(withJSONObject: manifest)
      try data.write(to: inbox.appendingPathComponent(Self.manifestName), options: .atomic)
      return true
    } catch {
      try? FileManager.default.removeItem(at: inbox)
      return false
    }
  }

  private func finish(opening: Bool) {
    if opening, let url = URL(string: "nymchat://share") {
      openHost(url)
    }
    extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
  }

  private func cancel() {
    let error = NSError(domain: "app.nymchat.share", code: 1)
    extensionContext?.cancelRequest(withError: error)
  }

  private func openHost(_ url: URL) {
    typealias OpenURL = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, AnyObject?) -> Void
    let selector = NSSelectorFromString("openURL:options:completionHandler:")
    var responder: UIResponder? = self
    while let current = responder {
      if let application = current as? UIApplication, application.responds(to: selector),
        let method = application.method(for: selector)
      {
        let open = unsafeBitCast(method, to: OpenURL.self)
        open(application, selector, url as NSURL, NSDictionary(), nil)
        return
      }
      responder = current.next
    }
    extensionContext?.open(url, completionHandler: nil)
  }

  static func displayName(_ raw: String?, type: UTType?) -> String {
    var name = sanitize(raw ?? "")
    if (name as NSString).pathExtension.isEmpty, let ext = type?.preferredFilenameExtension {
      name += "." + ext
    }
    return name
  }

  static func sanitize(_ raw: String) -> String {
    let base = raw.replacingOccurrences(of: "\\", with: "/")
      .components(separatedBy: "/").last ?? ""
    let banned = CharacterSet(charactersIn: ":*?\"<>|").union(.controlCharacters)
    let underscore: Unicode.Scalar = "_"
    var scalars = String.UnicodeScalarView()
    for scalar in base.unicodeScalars {
      scalars.append(banned.contains(scalar) ? underscore : scalar)
    }
    var clean = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
    while clean.hasPrefix(".") {
      clean.removeFirst()
    }
    if clean.isEmpty { return "shared" }
    return clean.count > 120 ? String(clean.suffix(120)) : clean
  }
}
