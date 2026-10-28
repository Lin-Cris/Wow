import UIKit
import UniformTypeIdentifiers

final class CounterShareViewController: UIViewController {
    private let statusLabel = UILabel()
    private var didFinish = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        statusLabel.text = "正在安全保存分享内容…"
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.font = .preferredFont(forTextStyle: .headline)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            statusLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
        receive()
    }

    private func receive() {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.counter.app") else {
            finish(successes: 0, failures: ["Counter 收件箱不可用"])
            return
        }
        let inbox = container.appendingPathComponent("CounterInbox", isDirectory: true)
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }
            .filter { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) ||
                      $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) }
        guard !providers.isEmpty else {
            finish(successes: 0, failures: ["没有可接收的图片或文本"])
            return
        }

        let selected = Array(providers.prefix(5))
        let batch = ShareBatchReceipt()
        let group = DispatchGroup()
        for provider in selected {
            group.enter()
            let kind = provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) ? "image" : "text"
            let completion: (Data?, Error?) -> Void = { data, error in
                if let error {
                    batch.recordFailure(error.localizedDescription)
                } else if let data {
                    do {
                        try SharedInboxItem.persist(data, id: UUID().uuidString.lowercased(), kind: kind, in: inbox)
                        batch.recordSuccess()
                    } catch {
                        batch.recordFailure(error.localizedDescription)
                    }
                } else {
                    batch.recordFailure("分享项目没有可读取的数据")
                }
                group.leave()
            }

            if kind == "image" {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier, completionHandler: completion)
            } else {
                provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, error in
                    let data: Data?
                    if let value = item as? String { data = value.data(using: .utf8) }
                    else if let value = item as? Data { data = value }
                    else if let url = item as? URL { data = try? Data(contentsOf: url) }
                    else { data = nil }
                    completion(data, error)
                }
            }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            let result = batch.snapshot
            let overLimit = providers.count - selected.count
            var failures = result.failures
            if overLimit > 0 { failures.append("超出 5 项的 \(overLimit) 项未接收") }
            self.finish(successes: result.successes, failures: failures)
        }
    }

    private func finish(successes: Int, failures: [String]) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.didFinish else { return }
            self.didFinish = true
            if failures.isEmpty {
                self.statusLabel.text = "已收到 \(successes) 项，正在加入 Counter 待记账"
            } else if successes == 0 {
                self.statusLabel.text = "未能接收分享内容\n\(failures.prefix(2).joined(separator: "\n"))"
            } else {
                self.statusLabel.text = "已收到 \(successes) 项，\(failures.count) 项未收到\n\(failures.prefix(2).joined(separator: "\n"))"
            }
            let delay = failures.isEmpty ? 0.8 : 2.2
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.extensionContext?.completeRequest(returningItems: nil)
            }
        }
    }
}

private final class ShareBatchReceipt {
    private let lock = NSLock()
    private var successCount = 0
    private var failureMessages: [String] = []

    func recordSuccess() {
        lock.lock(); defer { lock.unlock() }
        successCount += 1
    }

    func recordFailure(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        failureMessages.append(message)
    }

    var snapshot: (successes: Int, failures: [String]) {
        lock.lock(); defer { lock.unlock() }
        return (successCount, failureMessages)
    }
}
