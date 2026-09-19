import Foundation
import UIKit
import Display
import AccountContext
import TelegramPresentationData
import AorusGram

public func aorusPluginsController(context: AccountContext) -> ViewController {
    AorusPluginRuntimeManager.shared.configure(context: context)
    return AorusPluginsListController(context: context)
}

public func aorusPluginsTitle() -> String {
    return AorusPluginUIString.plugins.text
}

// Every string this screen shows goes through `aorusL`, the same helper and the same table as
// the rest of AorusGram's own UI. The release verifier walks those call sites and requires a
// translation for each one in all 32 further languages, so a plugin screen can never be the
// one place that falls back to English.
private enum AorusPluginUIString {
    case plugins, emptyTitle, emptyBody, create, importFile, enabled, autostart, editCode
    case configure, settings, permissions, duplicate, export, delete, save, run, stop, console, documentation
    case name, description, version, author, icon, accent, reviewPermissions, grantAndEnable, noPermissions, syntaxReady

    var text: String {
        switch self {
        case .plugins: return aorusL("Плагины", "Plugins")
        case .emptyTitle: return aorusL("Плагинов пока нет", "No plugins yet")
        case .emptyBody: return aorusL("Создайте свой или импортируйте готовый файл.", "Create your own plugin or import a file.")
        case .create: return aorusL("Создать плагин", "Create Plugin")
        case .importFile: return aorusL("Импортировать файл", "Import File")
        case .enabled: return aorusL("Включен", "Enabled")
        case .autostart: return aorusL("Автозапуск", "Run at Launch")
        case .editCode: return aorusL("Редактор", "Editor")
        case .configure: return aorusL("Оформление", "Appearance")
        case .settings: return aorusL("Настройки", "Settings")
        case .permissions: return aorusL("Разрешения", "Permissions")
        case .duplicate: return aorusL("Дублировать", "Duplicate")
        case .export: return aorusL("Экспортировать", "Export")
        case .delete: return aorusL("Удалить", "Delete")
        case .save: return aorusL("Сохранить", "Save")
        case .run: return aorusL("Запустить", "Run")
        case .stop: return aorusL("Остановить", "Stop")
        case .console: return aorusL("Консоль", "Console")
        case .documentation: return aorusL("Документация", "Documentation")
        case .name: return aorusL("Название", "Name")
        case .description: return aorusL("Описание", "Description")
        case .version: return aorusL("Версия", "Version")
        case .author: return aorusL("Автор", "Author")
        case .icon: return aorusL("Иконка", "Icon")
        case .accent: return aorusL("Цвет", "Color")
        case .reviewPermissions: return aorusL("Проверьте разрешения", "Review Permissions")
        case .grantAndEnable: return aorusL("Разрешить и включить", "Allow and Enable")
        case .noPermissions: return aorusL("Дополнительные разрешения не требуются", "No additional permissions are required")
        case .syntaxReady: return aorusL("Ошибок синтаксиса нет", "No syntax errors")
        }
    }
}

private final class AorusPluginsListController: ViewController, UITableViewDataSource, UITableViewDelegate, UIDocumentPickerDelegate {
    private let context: AccountContext
    private let presentationData: PresentationData
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let emptyView = AorusPluginsEmptyView()
    private var manifests: [AorusPluginManifest] = []
    private var observer: NSObjectProtocol?

    init(context: AccountContext) {
        self.context = context
        self.presentationData = context.sharedContext.currentPresentationData.with { $0 }
        super.init(navigationBarPresentationData: NavigationBarPresentationData(presentationData: presentationData, style: .glass))
        title = AorusPluginUIString.plugins.text
        statusBar.statusBarStyle = presentationData.theme.rootController.statusBarStyle.style
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .add, target: self, action: #selector(addPlugin))
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    override func loadDisplayNode() {
        displayNode = ViewControllerTracingNode()
        let theme = presentationData.theme
        displayNode.backgroundColor = theme.list.blocksBackgroundColor
        tableView.backgroundColor = theme.list.blocksBackgroundColor
        tableView.separatorColor = theme.list.itemBlocksSeparatorColor
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(AorusPluginCell.self, forCellReuseIdentifier: "plugin")
        emptyView.configure(theme: theme)
        emptyView.onCreate = { [weak self] in self?.createPlugin() }
        tableView.backgroundView = emptyView
        displayNode.view.addSubview(tableView)
        observer = NotificationCenter.default.addObserver(forName: AorusPluginStore.changedNotification, object: nil, queue: .main) { [weak self] _ in self?.reload() }
        reload()
        displayNodeDidLoad()
    }

    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        let top = navigationLayout(layout: layout).navigationFrame.maxY
        transition.updateFrame(view: tableView, frame: CGRect(x: 0, y: top, width: layout.size.width, height: layout.size.height - top))
        tableView.contentInset.bottom = layout.intrinsicInsets.bottom
    }

    private func reload() {
        manifests = AorusPluginStore.shared.list()
        emptyView.isHidden = !manifests.isEmpty
        tableView.reloadData()
    }

    @objc private func addPlugin() {
        let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: AorusPluginUIString.create.text, style: .default) { [weak self] _ in self?.createPlugin() })
        sheet.addAction(UIAlertAction(title: AorusPluginUIString.importFile.text, style: .default) { [weak self] _ in self?.importPlugin() })
        sheet.addAction(UIAlertAction(title: presentationData.strings.Common_Cancel, style: .cancel))
        if let popover = sheet.popoverPresentationController { popover.barButtonItem = navigationItem.rightBarButtonItem }
        present(sheet, animated: true)
    }

    private func createPlugin() {
        let manifest = AorusPluginManifest(name: AorusPluginUIString.plugins.text, autostart: false)
        let source = """
        // AorusGram Plugin API v1
        aorus.on('start', function () {
          console.log('Plugin started');
        });
        """
        let record = AorusPluginRecord(manifest: manifest, source: source)
        do {
            try AorusPluginStore.shared.save(record)
            pushEditor(record: AorusPluginStore.shared.load(id: manifest.id) ?? record)
        } catch { showError(error) }
    }

    private func importPlugin() {
        let picker = UIDocumentPickerViewController(documentTypes: ["public.data", "com.netscape.javascript-source"], in: .import)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let fallback = url.deletingPathExtension().lastPathComponent
            let manifest = try AorusPluginStore.shared.importPlugin(data: data, fallbackName: fallback)
            if let record = AorusPluginStore.shared.load(id: manifest.id) { pushEditor(record: record) }
        } catch { showError(error) }
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { manifests.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "plugin", for: indexPath) as! AorusPluginCell
        let manifest = manifests[indexPath.row]
        cell.configure(manifest: manifest, theme: presentationData.theme)
        cell.onToggle = { [weak self] value in self?.setEnabled(value, manifest: manifest) }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let record = AorusPluginStore.shared.load(id: manifests[indexPath.row].id) else { return }
        (navigationController as? NavigationController)?.pushViewController(AorusPluginDetailController(context: context, record: record))
    }

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let manifest = manifests[indexPath.row]
        let delete = UIContextualAction(style: .destructive, title: AorusPluginUIString.delete.text) { _, _, done in
            AorusPluginRuntimeManager.shared.stop(id: manifest.id)
            do { try AorusPluginStore.shared.delete(id: manifest.id); done(true) } catch { self.showError(error); done(false) }
        }
        let duplicate = UIContextualAction(style: .normal, title: AorusPluginUIString.duplicate.text) { _, _, done in
            do { _ = try AorusPluginStore.shared.duplicate(id: manifest.id); done(true) } catch { self.showError(error); done(false) }
        }
        return UISwipeActionsConfiguration(actions: [delete, duplicate])
    }

    private func setEnabled(_ enabled: Bool, manifest: AorusPluginManifest) {
        guard var record = AorusPluginStore.shared.load(id: manifest.id) else { return }
        if !enabled {
            record.manifest.isEnabled = false
            try? AorusPluginStore.shared.updateManifest(record.manifest)
            AorusPluginRuntimeManager.shared.stop(id: manifest.id)
            return
        }
        let diagnostics = AorusPluginSandbox.checkSyntax(record.source)
        guard diagnostics.isEmpty else { showError(AorusPluginRequestError(diagnostics[0].message)); return }
        let requested = AorusPluginPermission.requestedBySource(record.source)
        presentPermissionReview(record: record, requested: requested)
    }

    private func presentPermissionReview(record: AorusPluginRecord, requested: Set<AorusPluginPermission>) {
        let lines = requested.sorted { $0.rawValue < $1.rawValue }.map { "• \(permissionTitle($0))" }
        let message = lines.isEmpty ? AorusPluginUIString.noPermissions.text : lines.joined(separator: "\n")
        let alert = UIAlertController(title: AorusPluginUIString.reviewPermissions.text, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: presentationData.strings.Common_Cancel, style: .cancel) { _ in self.reload() })
        alert.addAction(UIAlertAction(title: AorusPluginUIString.grantAndEnable.text, style: .default) { _ in
            do {
                try AorusPluginStore.shared.setPermissionState(AorusPluginPermissionState(sourceDigest: AorusPluginStore.sourceDigest(record.source), granted: requested), for: record.manifest.id)
                var manifest = record.manifest
                manifest.isEnabled = true
                try AorusPluginStore.shared.updateManifest(manifest)
                AorusPluginRuntimeManager.shared.start(id: manifest.id) { error in
                    guard let error else { return }
                    DispatchQueue.main.async {
                        var disabled = manifest
                        disabled.isEnabled = false
                        try? AorusPluginStore.shared.updateManifest(disabled)
                        self.showError(AorusPluginRequestError(error.message))
                    }
                }
            } catch { self.showError(error) }
        })
        present(alert, animated: true)
    }

    private func pushEditor(record: AorusPluginRecord) {
        (navigationController as? NavigationController)?.pushViewController(AorusPluginEditorController(context: context, record: record))
    }

    private func showError(_ error: Error) {
        let alert = UIAlertController(title: AorusPluginUIString.plugins.text, message: (error as? AorusPluginRequestError)?.message ?? error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

private final class AorusPluginDetailController: ViewController, UITableViewDataSource, UITableViewDelegate {
    private let context: AccountContext
    private let presentationData: PresentationData
    private var record: AorusPluginRecord
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private var observer: NSObjectProtocol?

    init(context: AccountContext, record: AorusPluginRecord) {
        self.context = context; self.record = record
        self.presentationData = context.sharedContext.currentPresentationData.with { $0 }
        super.init(navigationBarPresentationData: NavigationBarPresentationData(presentationData: presentationData, style: .glass))
        title = record.manifest.name
        statusBar.statusBarStyle = presentationData.theme.rootController.statusBarStyle.style
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    override func loadDisplayNode() {
        displayNode = ViewControllerTracingNode(); displayNode.backgroundColor = presentationData.theme.list.blocksBackgroundColor
        tableView.backgroundColor = presentationData.theme.list.blocksBackgroundColor
        tableView.dataSource = self; tableView.delegate = self
        displayNode.view.addSubview(tableView)
        observer = NotificationCenter.default.addObserver(forName: AorusPluginStore.changedNotification, object: nil, queue: .main) { [weak self] _ in self?.reload() }
        displayNodeDidLoad()
    }

    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        let top = navigationLayout(layout: layout).navigationFrame.maxY
        transition.updateFrame(view: tableView, frame: CGRect(x: 0, y: top, width: layout.size.width, height: layout.size.height - top))
    }

    private func reload() {
        guard let updated = AorusPluginStore.shared.load(id: record.manifest.id) else { return }
        record = updated; title = updated.manifest.name; tableView.reloadData()
    }

    func numberOfSections(in tableView: UITableView) -> Int { 3 }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { section == 0 ? 2 : (section == 1 ? 5 : 3) }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        cell.backgroundColor = presentationData.theme.list.itemBlocksBackgroundColor
        cell.textLabel?.textColor = presentationData.theme.list.itemPrimaryTextColor
        if indexPath.section == 0 {
            let toggle = UISwitch()
            if indexPath.row == 0 { cell.textLabel?.text = AorusPluginUIString.enabled.text; toggle.isOn = record.manifest.isEnabled; toggle.addTarget(self, action: #selector(enabledChanged(_:)), for: .valueChanged) }
            else { cell.textLabel?.text = AorusPluginUIString.autostart.text; toggle.isOn = record.manifest.autostart; toggle.addTarget(self, action: #selector(autostartChanged(_:)), for: .valueChanged) }
            cell.accessoryView = toggle
        } else if indexPath.section == 1 {
            let titles = [AorusPluginUIString.configure.text, AorusPluginUIString.editCode.text, AorusPluginUIString.settings.text, AorusPluginUIString.permissions.text, AorusPluginUIString.documentation.text]
            cell.textLabel?.text = titles[indexPath.row]; cell.accessoryType = .disclosureIndicator
        } else {
            let actionTitles = [AorusPluginUIString.duplicate.text, AorusPluginUIString.export.text, AorusPluginUIString.delete.text]
            cell.textLabel?.text = actionTitles[indexPath.row]
            if indexPath.row == 2 { cell.textLabel?.textColor = presentationData.theme.list.itemDestructiveColor }
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.section != 0 else { return }
        if indexPath.section == 1 {
            switch indexPath.row {
            case 0: (navigationController as? NavigationController)?.pushViewController(AorusPluginMetadataController(context: context, record: record))
            case 1: (navigationController as? NavigationController)?.pushViewController(AorusPluginEditorController(context: context, record: record))
            case 2: (navigationController as? NavigationController)?.pushViewController(AorusPluginSettingsController(context: context, record: record))
            case 3: (navigationController as? NavigationController)?.pushViewController(AorusPluginPermissionsController(context: context, record: record))
            default: (navigationController as? NavigationController)?.pushViewController(AorusPluginDocsController(context: context))
            }
        } else {
            switch indexPath.row {
            case 0: do { _ = try AorusPluginStore.shared.duplicate(id: record.manifest.id) } catch { show(error) }
            case 1: exportPlugin()
            default: confirmDelete()
            }
        }
    }

    @objc private func enabledChanged(_ sender: UISwitch) {
        if sender.isOn {
            let diagnostics = AorusPluginSandbox.checkSyntax(record.source)
            guard diagnostics.isEmpty else {
                sender.setOn(false, animated: true)
                show(AorusPluginRequestError(diagnostics[0].message))
                return
            }
            let requested = AorusPluginPermission.requestedBySource(record.source)
            let alert = UIAlertController(title: AorusPluginUIString.reviewPermissions.text, message: requested.map(permissionTitle).sorted().joined(separator: "\n"), preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: presentationData.strings.Common_Cancel, style: .cancel) { _ in sender.setOn(false, animated: true) })
            alert.addAction(UIAlertAction(title: AorusPluginUIString.grantAndEnable.text, style: .default) { _ in
                do {
                    try AorusPluginStore.shared.setPermissionState(AorusPluginPermissionState(sourceDigest: AorusPluginStore.sourceDigest(self.record.source), granted: requested), for: self.record.manifest.id)
                    self.record.manifest.isEnabled = true; try AorusPluginStore.shared.updateManifest(self.record.manifest)
                    AorusPluginRuntimeManager.shared.start(id: self.record.manifest.id) { error in
                        guard let error else { return }
                        DispatchQueue.main.async {
                            self.record.manifest.isEnabled = false
                            try? AorusPluginStore.shared.updateManifest(self.record.manifest)
                            sender.setOn(false, animated: true)
                            self.show(AorusPluginRequestError(error.message))
                        }
                    }
                } catch { sender.setOn(false, animated: true); self.show(error) }
            })
            present(alert, animated: true)
        } else {
            record.manifest.isEnabled = false; try? AorusPluginStore.shared.updateManifest(record.manifest)
            AorusPluginRuntimeManager.shared.stop(id: record.manifest.id)
        }
    }

    @objc private func autostartChanged(_ sender: UISwitch) { record.manifest.autostart = sender.isOn; try? AorusPluginStore.shared.updateManifest(record.manifest) }

    private func exportPlugin() {
        guard let data = AorusPluginStore.shared.export(id: record.manifest.id) else { return }
        let safe = record.manifest.name.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(safe).appendingPathExtension("aorusplugin")
        do { try data.write(to: url, options: .atomic); present(UIActivityViewController(activityItems: [url], applicationActivities: nil), animated: true) } catch { show(error) }
    }

    private func confirmDelete() {
        let alert = UIAlertController(title: AorusPluginUIString.delete.text, message: record.manifest.name, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: presentationData.strings.Common_Cancel, style: .cancel))
        alert.addAction(UIAlertAction(title: AorusPluginUIString.delete.text, style: .destructive) { _ in
            AorusPluginRuntimeManager.shared.stop(id: self.record.manifest.id)
            try? AorusPluginStore.shared.delete(id: self.record.manifest.id)
            _ = self.navigationController?.popViewController(animated: true)
        }); present(alert, animated: true)
    }

    private func show(_ error: Error) { let alert = UIAlertController(title: AorusPluginUIString.plugins.text, message: error.localizedDescription, preferredStyle: .alert); alert.addAction(UIAlertAction(title: "OK", style: .default)); present(alert, animated: true) }
}

private final class AorusPluginMetadataController: ViewController, UITableViewDataSource, UITableViewDelegate {
    private let presentationData: PresentationData
    private var record: AorusPluginRecord
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)

    init(context: AccountContext, record: AorusPluginRecord) {
        self.presentationData = context.sharedContext.currentPresentationData.with { $0 }
        self.record = record
        super.init(navigationBarPresentationData: NavigationBarPresentationData(presentationData: presentationData, style: .glass))
        title = AorusPluginUIString.configure.text
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadDisplayNode() {
        displayNode = ViewControllerTracingNode()
        displayNode.backgroundColor = presentationData.theme.list.blocksBackgroundColor
        tableView.backgroundColor = presentationData.theme.list.blocksBackgroundColor
        tableView.dataSource = self
        tableView.delegate = self
        displayNode.view.addSubview(tableView)
        displayNodeDidLoad()
    }

    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        let top = navigationLayout(layout: layout).navigationFrame.maxY
        transition.updateFrame(view: tableView, frame: CGRect(x: 0, y: top, width: layout.size.width, height: layout.size.height - top))
    }

    func numberOfSections(in tableView: UITableView) -> Int { 2 }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { section == 0 ? 4 : 2 }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        cell.backgroundColor = presentationData.theme.list.itemBlocksBackgroundColor
        cell.textLabel?.textColor = presentationData.theme.list.itemPrimaryTextColor
        cell.detailTextLabel?.textColor = presentationData.theme.list.itemSecondaryTextColor
        cell.accessoryType = .disclosureIndicator
        if indexPath.section == 0 {
            let labels = [AorusPluginUIString.name.text, AorusPluginUIString.description.text, AorusPluginUIString.version.text, AorusPluginUIString.author.text]
            let values = [record.manifest.name, record.manifest.summary, record.manifest.version, record.manifest.author]
            cell.textLabel?.text = labels[indexPath.row]
            cell.detailTextLabel?.text = values[indexPath.row]
        } else if indexPath.row == 0 {
            cell.textLabel?.text = AorusPluginUIString.icon.text
            cell.detailTextLabel?.text = record.manifest.icon
            cell.imageView?.image = UIImage(systemName: AorusPluginIcon.normalized(record.manifest.icon))
            cell.imageView?.tintColor = presentationData.theme.list.itemAccentColor
        } else {
            cell.textLabel?.text = AorusPluginUIString.accent.text
            cell.detailTextLabel?.text = "#\(record.manifest.accent)"
            let swatch = UIView(frame: CGRect(x: 0, y: 0, width: 24, height: 24))
            swatch.backgroundColor = pluginColor(record.manifest.accent)
            swatch.layer.cornerRadius = 12
            swatch.layer.borderWidth = 1.0 / UIScreen.main.scale
            swatch.layer.borderColor = UIColor.separator.cgColor
            cell.accessoryView = swatch
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.section == 0 { editText(row: indexPath.row); return }
        let sheet = UIAlertController(title: indexPath.row == 0 ? AorusPluginUIString.icon.text : AorusPluginUIString.accent.text, message: nil, preferredStyle: .actionSheet)
        if indexPath.row == 0 {
            for icon in AorusPluginIcon.all {
                sheet.addAction(UIAlertAction(title: icon, style: .default) { _ in
                    self.record.manifest.icon = icon
                    self.persist()
                })
            }
        } else {
            for accent in AorusPluginAccent.all {
                sheet.addAction(UIAlertAction(title: "●  #\(accent)", style: .default) { _ in
                    self.record.manifest.accent = accent
                    self.persist()
                })
            }
        }
        sheet.addAction(UIAlertAction(title: presentationData.strings.Common_Cancel, style: .cancel))
        if let popover = sheet.popoverPresentationController, let cell = tableView.cellForRow(at: indexPath) {
            popover.sourceView = cell
            popover.sourceRect = cell.bounds
        }
        present(sheet, animated: true)
    }

    private func editText(row: Int) {
        let labels = [AorusPluginUIString.name.text, AorusPluginUIString.description.text, AorusPluginUIString.version.text, AorusPluginUIString.author.text]
        let values = [record.manifest.name, record.manifest.summary, record.manifest.version, record.manifest.author]
        let alert = UIAlertController(title: labels[row], message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.text = values[row]
            field.clearButtonMode = .whileEditing
        }
        alert.addAction(UIAlertAction(title: presentationData.strings.Common_Cancel, style: .cancel))
        alert.addAction(UIAlertAction(title: AorusPluginUIString.save.text, style: .default) { _ in
            let value = alert.textFields?.first?.text ?? ""
            switch row {
            case 0: self.record.manifest.name = value
            case 1: self.record.manifest.summary = value
            case 2: self.record.manifest.version = value
            default: self.record.manifest.author = value
            }
            self.persist()
        })
        present(alert, animated: true)
    }

    private func persist() {
        do {
            try AorusPluginStore.shared.updateManifest(record.manifest)
            if let saved = AorusPluginStore.shared.load(id: record.manifest.id) { record = saved }
            tableView.reloadData()
        } catch {
            let alert = UIAlertController(title: AorusPluginUIString.configure.text, message: error.localizedDescription, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
        }
    }
}

private final class AorusPluginEditorController: ViewController, UITextViewDelegate {
    private let context: AccountContext
    private let presentationData: PresentationData
    private var record: AorusPluginRecord
    private let editor = UITextView()
    private let lineNumbers = UITextView()
    private let console = UITextView()
    private let toolbar = UIStackView()
    private var debugSandbox: AorusPluginSandbox?
    private var highlightWork: DispatchWorkItem?
    private var currentLayout: ContainerViewLayout?

    init(context: AccountContext, record: AorusPluginRecord) {
        self.context = context; self.record = record; self.presentationData = context.sharedContext.currentPresentationData.with { $0 }
        super.init(navigationBarPresentationData: NavigationBarPresentationData(presentationData: presentationData, style: .glass))
        title = record.manifest.name
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(title: AorusPluginUIString.save.text, style: .done, target: self, action: #selector(save)),
            UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"), style: .plain, target: self, action: #selector(editMetadata))
        ]
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadDisplayNode() {
        displayNode = ViewControllerTracingNode()
        let dark = presentationData.theme.overallDarkAppearance
        let background = dark ? UIColor(red: 0.055, green: 0.059, blue: 0.071, alpha: 1) : UIColor(red: 0.96, green: 0.97, blue: 0.98, alpha: 1)
        displayNode.backgroundColor = background
        lineNumbers.font = .monospacedSystemFont(ofSize: 13, weight: .regular); lineNumbers.textColor = .secondaryLabel; lineNumbers.textAlignment = .right; lineNumbers.backgroundColor = .clear; lineNumbers.isEditable = false; lineNumbers.isSelectable = false; lineNumbers.isUserInteractionEnabled = false; lineNumbers.textContainerInset = UIEdgeInsets(top: 14, left: 0, bottom: 80, right: 2); lineNumbers.textContainer.lineFragmentPadding = 0
        editor.backgroundColor = .clear; editor.textColor = dark ? .white : .black; editor.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        editor.autocorrectionType = .no; editor.autocapitalizationType = .none; editor.smartQuotesType = .no; editor.smartDashesType = .no
        editor.textContainerInset = UIEdgeInsets(top: 14, left: 8, bottom: 80, right: 12); editor.delegate = self; editor.text = record.source
        console.backgroundColor = UIColor.black.withAlphaComponent(0.94); console.textColor = UIColor(red: 0.55, green: 0.95, blue: 0.68, alpha: 1); console.font = .monospacedSystemFont(ofSize: 12, weight: .regular); console.isEditable = false; console.isHidden = true
        toolbar.axis = .horizontal; toolbar.distribution = .fillEqually; toolbar.backgroundColor = dark ? UIColor(white: 0.12, alpha: 0.94) : UIColor(white: 1, alpha: 0.96)
        addTool(AorusPluginUIString.run.text, "play.fill", #selector(runPlugin)); addTool(AorusPluginUIString.stop.text, "stop.fill", #selector(stopPlugin)); addTool(AorusPluginUIString.console.text, "terminal.fill", #selector(toggleConsole)); addTool(AorusPluginUIString.documentation.text, "book.fill", #selector(openDocs))
        displayNode.view.addSubview(lineNumbers); displayNode.view.addSubview(editor); displayNode.view.addSubview(console); displayNode.view.addSubview(toolbar)
        updateLineNumbers(); highlight(); displayNodeDidLoad()
    }

    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        currentLayout = layout
        let top = navigationLayout(layout: layout).navigationFrame.maxY
        let toolbarHeight: CGFloat = 52 + layout.intrinsicInsets.bottom
        let consoleHeight: CGFloat = console.isHidden ? 0 : min(190, layout.size.height * 0.28)
        transition.updateFrame(view: lineNumbers, frame: CGRect(x: 6, y: top + 14, width: 34, height: max(0, layout.size.height - top - toolbarHeight - 14)))
        transition.updateFrame(view: editor, frame: CGRect(x: 40, y: top, width: layout.size.width - 40, height: max(0, layout.size.height - top - toolbarHeight - consoleHeight)))
        transition.updateFrame(view: console, frame: CGRect(x: 0, y: layout.size.height - toolbarHeight - consoleHeight, width: layout.size.width, height: consoleHeight))
        transition.updateFrame(view: toolbar, frame: CGRect(x: 0, y: layout.size.height - toolbarHeight, width: layout.size.width, height: toolbarHeight))
    }

    private func addTool(_ title: String, _ image: String, _ action: Selector) { let button = UIButton(type: .system); button.setImage(UIImage(systemName: image), for: .normal); button.setTitle(" " + title, for: .normal); button.titleLabel?.font = .systemFont(ofSize: 12, weight: .semibold); button.addTarget(self, action: action, for: .touchUpInside); toolbar.addArrangedSubview(button) }

    func textViewDidChange(_ textView: UITextView) { updateLineNumbers(); highlightWork?.cancel(); let work = DispatchWorkItem { [weak self] in self?.highlight() }; highlightWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work) }

    private func updateLineNumbers() { let count = max(1, editor.text.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }); lineNumbers.text = (1...count).map(String.init).joined(separator: "\n") }

    private func highlight() {
        let selected = editor.selectedRange; let text = editor.text ?? ""; let storage = editor.textStorage
        let dark = presentationData.theme.overallDarkAppearance
        storage.beginEditing(); storage.setAttributes([.font: UIFont.monospacedSystemFont(ofSize: 14, weight: .regular), .foregroundColor: dark ? UIColor.white : UIColor.black], range: NSRange(location: 0, length: storage.length))
        for token in AorusJavaScriptTokenizer.tokenize(text) {
            let color: UIColor
            switch token.kind { case .keyword: color = .systemPink; case .string, .template: color = .systemGreen; case .comment: color = .systemGray; case .number, .literal: color = .systemOrange; case .api: color = .systemPurple; case .function: color = .systemBlue; case .regex: color = .systemTeal; default: continue }
            if NSMaxRange(token.range) <= storage.length { storage.addAttribute(.foregroundColor, value: color, range: token.range) }
        }
        storage.endEditing(); editor.selectedRange = selected
    }

    @objc private func save() {
        let source = editor.text ?? ""
        let sourceChanged = source != record.source
        record.source = source
        do {
            if sourceChanged {
                stopPlugin()
                AorusPluginRuntimeManager.shared.stop(id: record.manifest.id)
            }
            try AorusPluginStore.shared.save(record)
            if let saved = AorusPluginStore.shared.load(id: record.manifest.id) {
                record = saved
            }
            title = record.manifest.name
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } catch {
            appendConsole("ERROR: \(error.localizedDescription)")
        }
    }

    @objc private func runPlugin() {
        stopPlugin(); record.source = editor.text ?? ""
        let diagnostics = AorusPluginSandbox.checkSyntax(record.source)
        guard diagnostics.isEmpty else { appendConsole("Line \(diagnostics[0].line): \(diagnostics[0].message)"); return }
        let host = AorusPluginNullHost(); host.onLog = { [weak self] _, level, text in DispatchQueue.main.async { self?.appendConsole("[\(level.rawValue)] \(text)") } }
        let permissions = AorusPluginStore.shared.permissionState(for: record.manifest.id).granted
        let sandbox = AorusPluginSandbox(manifest: record.manifest, source: record.source, host: host, permissions: permissions, storage: AorusPluginStore.shared.storage(for: record.manifest.id), settings: AorusPluginStore.shared.settings(for: record.manifest.id))
        debugSandbox = sandbox; console.isHidden = false; updateLayout(animated: true)
        sandbox.start { [weak self] error in if let error { DispatchQueue.main.async { self?.appendConsole("ERROR: \(error.message)") } } else { DispatchQueue.main.async { self?.appendConsole(AorusPluginUIString.syntaxReady.text) } } }
    }

    @objc private func stopPlugin() { debugSandbox?.stop(); debugSandbox = nil }
    @objc private func toggleConsole() { console.isHidden.toggle(); updateLayout(animated: true) }
    @objc private func openDocs() { (navigationController as? NavigationController)?.pushViewController(AorusPluginDocsController(context: context)) }
    @objc private func editMetadata() {
        let alert = UIAlertController(title: AorusPluginUIString.editCode.text, message: nil, preferredStyle: .alert)
        alert.addTextField { $0.placeholder = AorusPluginUIString.name.text; $0.text = self.record.manifest.name }
        alert.addTextField { $0.placeholder = AorusPluginUIString.description.text; $0.text = self.record.manifest.summary }
        alert.addTextField { $0.placeholder = AorusPluginUIString.version.text; $0.text = self.record.manifest.version }
        alert.addAction(UIAlertAction(title: presentationData.strings.Common_Cancel, style: .cancel))
        alert.addAction(UIAlertAction(title: AorusPluginUIString.save.text, style: .default) { _ in self.record.manifest.name = alert.textFields?[0].text ?? self.record.manifest.name; self.record.manifest.summary = alert.textFields?[1].text ?? ""; self.record.manifest.version = alert.textFields?[2].text ?? "1.0.0"; self.save() })
        present(alert, animated: true)
    }
    private func appendConsole(_ text: String) { console.text += (console.text.isEmpty ? "" : "\n") + text; console.scrollRangeToVisible(NSRange(location: max(0, console.text.count - 1), length: 1)) }
    private func updateLayout(animated: Bool) {
        guard let layout = currentLayout else { return }
        containerLayoutUpdated(layout, transition: animated ? .animated(duration: 0.2, curve: .easeInOut) : .immediate)
    }
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === editor else { return }
        lineNumbers.contentOffset = CGPoint(x: 0, y: editor.contentOffset.y)
    }
}

private final class AorusPluginSettingsController: ViewController, UITableViewDataSource, UITableViewDelegate {
    private let context: AccountContext; private let presentationData: PresentationData; private let record: AorusPluginRecord
    private let tableView = UITableView(frame: .zero, style: .insetGrouped); private var fields: [AorusPluginSettingField] = []; private var values: [String: AorusPluginJSONValue]
    init(context: AccountContext, record: AorusPluginRecord) { self.context = context; self.record = record; self.presentationData = context.sharedContext.currentPresentationData.with { $0 }; self.values = AorusPluginStore.shared.settings(for: record.manifest.id); super.init(navigationBarPresentationData: NavigationBarPresentationData(presentationData: presentationData, style: .glass)); title = AorusPluginUIString.settings.text; fields = AorusPluginRuntimeManager.shared.settingsSchema(id: record.manifest.id) }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadDisplayNode() { displayNode = ViewControllerTracingNode(); displayNode.backgroundColor = presentationData.theme.list.blocksBackgroundColor; tableView.backgroundColor = presentationData.theme.list.blocksBackgroundColor; tableView.dataSource = self; tableView.delegate = self; displayNode.view.addSubview(tableView); displayNodeDidLoad() }
    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) { super.containerLayoutUpdated(layout, transition: transition); let top = navigationLayout(layout: layout).navigationFrame.maxY; transition.updateFrame(view: tableView, frame: CGRect(x: 0, y: top, width: layout.size.width, height: layout.size.height - top)) }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { fields.count }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let field = fields[indexPath.row]
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.text = field.title
        cell.detailTextLabel?.text = displayValue(for: field) ?? field.summary
        if field.kind == .toggle {
            let toggle = UISwitch()
            toggle.isOn = values[field.key]?.boolValue ?? field.defaultValue?.boolValue ?? false
            toggle.tag = indexPath.row
            toggle.addTarget(self, action: #selector(toggleChanged(_:)), for: .valueChanged)
            cell.accessoryView = toggle
        } else {
            cell.accessoryType = .disclosureIndicator
        }
        return cell
    }
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let field = fields[indexPath.row]
        guard field.kind != .toggle else { return }
        if field.kind == .select {
            let sheet = UIAlertController(title: field.title, message: field.summary, preferredStyle: .actionSheet)
            for option in field.options ?? [] {
                sheet.addAction(UIAlertAction(title: option.title, style: .default) { _ in
                    self.store(.string(option.value), field: field, indexPath: indexPath)
                })
            }
            sheet.addAction(UIAlertAction(title: presentationData.strings.Common_Cancel, style: .cancel))
            if let popover = sheet.popoverPresentationController, let cell = tableView.cellForRow(at: indexPath) {
                popover.sourceView = cell
                popover.sourceRect = cell.bounds
            }
            present(sheet, animated: true)
            return
        }
        let alert = UIAlertController(title: field.title, message: field.summary, preferredStyle: .alert)
        alert.addTextField {
            if field.kind == .number {
                let value = self.values[field.key]?.doubleValue ?? field.defaultValue?.doubleValue
                $0.text = value.map { String($0) }
                $0.keyboardType = .decimalPad
            } else {
                $0.text = self.values[field.key]?.stringValue ?? field.defaultValue?.stringValue
                $0.keyboardType = .default
            }
            $0.placeholder = field.placeholder
        }
        alert.addAction(UIAlertAction(title: presentationData.strings.Common_Cancel, style: .cancel))
        alert.addAction(UIAlertAction(title: AorusPluginUIString.save.text, style: .default) { _ in
            let text = alert.textFields?.first?.text ?? ""
            if field.kind == .number {
                guard var number = Double(text.replacingOccurrences(of: ",", with: ".")) else { return }
                if let minimum = field.minimum { number = max(minimum, number) }
                if let maximum = field.maximum { number = min(maximum, number) }
                self.store(.number(number), field: field, indexPath: indexPath)
            } else {
                self.store(.string(String(text.prefix(16_384))), field: field, indexPath: indexPath)
            }
        })
        present(alert, animated: true)
    }
    @objc private func toggleChanged(_ sender: UISwitch) { let field = fields[sender.tag]; values[field.key] = .bool(sender.isOn); try? AorusPluginStore.shared.setSettings(values, for: record.manifest.id); AorusPluginRuntimeManager.shared.sandbox(id: record.manifest.id)?.updateSettings(values) }
    private func displayValue(for field: AorusPluginSettingField) -> String? {
        let value = values[field.key] ?? field.defaultValue
        if let string = value?.stringValue {
            return field.options?.first(where: { $0.value == string })?.title ?? string
        }
        if let number = value?.doubleValue { return String(number) }
        return nil
    }
    private func store(_ value: AorusPluginJSONValue, field: AorusPluginSettingField, indexPath: IndexPath) {
        values[field.key] = value
        do {
            try AorusPluginStore.shared.setSettings(values, for: record.manifest.id)
            AorusPluginRuntimeManager.shared.sandbox(id: record.manifest.id)?.updateSettings(values)
            tableView.reloadRows(at: [indexPath], with: .none)
        } catch {
            let alert = UIAlertController(title: AorusPluginUIString.settings.text, message: error.localizedDescription, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
        }
    }
}

private final class AorusPluginPermissionsController: ViewController, UITableViewDataSource, UITableViewDelegate {
    private let context: AccountContext
    private let presentationData: PresentationData
    private var record: AorusPluginRecord
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let requested: Set<AorusPluginPermission>
    private var granted: Set<AorusPluginPermission>

    init(context: AccountContext, record: AorusPluginRecord) {
        self.context = context
        self.record = record
        self.presentationData = context.sharedContext.currentPresentationData.with { $0 }
        self.requested = AorusPluginPermission.requestedBySource(record.source)
        let state = AorusPluginStore.shared.permissionState(for: record.manifest.id)
        self.granted = state.sourceDigest == AorusPluginStore.sourceDigest(record.source) ? state.granted : []
        super.init(navigationBarPresentationData: NavigationBarPresentationData(presentationData: presentationData, style: .glass))
        title = AorusPluginUIString.permissions.text
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadDisplayNode() {
        displayNode = ViewControllerTracingNode()
        displayNode.backgroundColor = presentationData.theme.list.blocksBackgroundColor
        tableView.backgroundColor = presentationData.theme.list.blocksBackgroundColor
        tableView.dataSource = self
        tableView.delegate = self
        displayNode.view.addSubview(tableView)
        displayNodeDidLoad()
    }

    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        let top = navigationLayout(layout: layout).navigationFrame.maxY
        transition.updateFrame(view: tableView, frame: CGRect(x: 0, y: top, width: layout.size.width, height: layout.size.height - top))
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { AorusPluginPermission.allCases.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let permission = AorusPluginPermission.allCases[indexPath.row]
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.text = permissionTitle(permission)
        cell.detailTextLabel?.text = permissionDescription(permission, requested: requested.contains(permission))
        cell.detailTextLabel?.numberOfLines = 0
        let toggle = UISwitch()
        toggle.tag = indexPath.row
        toggle.isOn = granted.contains(permission)
        toggle.addTarget(self, action: #selector(permissionChanged(_:)), for: .valueChanged)
        cell.accessoryView = toggle
        cell.selectionStyle = .none
        return cell
    }

    @objc private func permissionChanged(_ sender: UISwitch) {
        let permission = AorusPluginPermission.allCases[sender.tag]
        if sender.isOn { granted.insert(permission) } else { granted.remove(permission) }
        do {
            try AorusPluginStore.shared.setPermissionState(
                AorusPluginPermissionState(sourceDigest: AorusPluginStore.sourceDigest(record.source), granted: granted),
                for: record.manifest.id
            )
            let canRun = requested.isSubset(of: granted)
            if !canRun && record.manifest.isEnabled {
                record.manifest.isEnabled = false
                try AorusPluginStore.shared.updateManifest(record.manifest)
                AorusPluginRuntimeManager.shared.stop(id: record.manifest.id)
            } else if record.manifest.isEnabled {
                AorusPluginRuntimeManager.shared.restart(id: record.manifest.id)
            }
        } catch {
            if sender.isOn { granted.remove(permission) } else { granted.insert(permission) }
            sender.setOn(!sender.isOn, animated: true)
            let alert = UIAlertController(title: AorusPluginUIString.permissions.text, message: error.localizedDescription, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
        }
    }
}

private final class AorusPluginDocsController: ViewController {
    private let presentationData: PresentationData; private let textView = UITextView()
    init(context: AccountContext) { presentationData = context.sharedContext.currentPresentationData.with { $0 }; super.init(navigationBarPresentationData: NavigationBarPresentationData(presentationData: presentationData, style: .glass)); title = AorusPluginUIString.documentation.text }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadDisplayNode() { displayNode = ViewControllerTracingNode(); displayNode.backgroundColor = presentationData.theme.list.blocksBackgroundColor; textView.backgroundColor = .clear; textView.textColor = presentationData.theme.list.itemPrimaryTextColor; textView.font = .systemFont(ofSize: 15); textView.isEditable = false; textView.alwaysBounceVertical = true; textView.textContainerInset = UIEdgeInsets(top: 18, left: 18, bottom: 40, right: 18); textView.text = AorusPluginDocumentation.text; displayNode.view.addSubview(textView); displayNodeDidLoad() }
    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) { super.containerLayoutUpdated(layout, transition: transition); let top = navigationLayout(layout: layout).navigationFrame.maxY; transition.updateFrame(view: textView, frame: CGRect(x: 0, y: top, width: layout.size.width, height: layout.size.height - top)) }
}

private enum AorusPluginDocumentation {
    static var text: String {
        if AorusLang.current == .ru {
            return """
            AorusGram Plugin API v1

            Среда выполнения
            Каждый плагин работает в отдельном контексте JavaScriptCore. У него нет доступа к файловой системе, нативным модулям, Keychain, лицензии, AorusAI или туннелю. Опасные возможности включаются только после подтверждения, а любое изменение кода отзывает все выданные разрешения.

            Жизненный цикл
            aorus.on('start', handler)
            aorus.on('stop', handler)
            aorus.on('foreground', handler)
            aorus.on('background', handler)

            События
            aorus.on(event, handler) возвращает функцию отписки. Также доступны aorus.once и aorus.off.
            message: { accountId, peerId, senderId, msgId, msgNs, peerKind, text, date }
            send: { accountId, peerId, text }
            Идентификаторы аккаунтов и чатов — десятичные строки. Событие message требует отдельного разрешения. Обработчик send может вернуть новую строку, false для отмены или ничего для отправки без изменений. Promise из send не задерживает отправку.

            Команды
            aorus.commands.register('name', (args, context) => result, { description, usage })
            aorus.commands.setPrefix('.')
            Синхронная строка заменяет введённую команду. Promise поглощает команду и после завершения отправляет строковый результат. Контекст содержит peerId, accountId, raw и command.

            Сообщения и чаты
            Идентификаторы peerId и accountId передаются десятичными строками без потери точности.
            await aorus.messages.send(peerId, text)
            await aorus.chats.resolve('username')
            await aorus.chats.get(peerId)
            await aorus.chats.open(peerId)
            await aorus.account.current()
            Используйте 'me' вместо peerId для текущего сохранённого чата. Отправка всегда выполняется только от активного аккаунта; подмена accountId отклоняется.

            Хранилище и настройки
            aorus.storage.get(key)
            aorus.storage.set(key, value)
            aorus.storage.remove(key)
            aorus.storage.keys()
            aorus.storage.clear()
            aorus.settings.define([{ key: 'enabled', type: 'toggle', title: 'Включено', default: true }])
            aorus.settings.get(key)
            aorus.settings.set(key, value)
            aorus.settings.all()
            Типы полей: toggle, text, multiline, number и select. Для number доступны min/max, для select — options: [{ value, title }]. Значения обязаны быть JSON-совместимыми.

            Сеть
            await aorus.http.fetch(url, { method: 'GET', headers: {}, timeout: 30000 })
            Запросы выполняются в отдельной сессии без cookies. Локальная сеть, loopback, служебные домены AorusGram и перенаправления на них заблокированы.
            Ответ содержит status, ok, url, headers, text() и json(). Методы: GET, HEAD, POST, PUT, PATCH, DELETE. При междоменном перенаправлении Authorization удаляется.

            Интерфейс
            aorus.ui.toast(text)
            await aorus.ui.alert(title, text)
            await aorus.ui.confirm(title, text)
            await aorus.ui.prompt(title, text)
            aorus.ui.haptic('light')

            Буфер обмена
            await aorus.clipboard.read()
            aorus.clipboard.write(text)

            Утилиты
            await aorus.util.sleep(milliseconds)
            aorus.crypto.sha256(text)
            aorus.crypto.hmacSHA256(key, text)
            aorus.crypto.randomUUID()
            aorus.crypto.randomBytes(count)
            aorus.crypto.base64Encode(text) / base64Decode(text)
            Доступны console.log/info/warn/error/debug, setTimeout, setInterval и функции отмены таймеров.

            Безопасность
            Импортированный плагин всегда выключен. Разрешения принадлежат конкретной установке, не экспортируются и отзываются при любом изменении исходника. Плагин не имеет API для файловой системы, Keychain, лицензии, AorusAI, VLESS, прокси или внутренних доменов AorusGram.

            Ограничения
            Код: 512 КБ. Хранилище: 1 МБ. HTTP-ответ: 5 МБ. Один вход в JavaScript прерывается через 3 секунды. На плагин разрешено до 64 таймеров и 32 незавершённых запросов к приложению.
            """
        }
        return """
    AorusGram Plugin API v1

    Runtime
    Each plugin runs in a separate JavaScriptCore context. There is no file system, native module loader, eval bridge, Keychain, license, AorusAI or tunnel access. Sensitive capabilities require approval and approvals are revoked whenever source code changes.

    Lifecycle
    aorus.on('start', handler)
    aorus.on('stop', handler)
    aorus.on('foreground', handler)
    aorus.on('background', handler)

    Events
    aorus.on(event, handler) returns an unsubscribe function. aorus.once and aorus.off are also available.
    message: { accountId, peerId, senderId, msgId, msgNs, peerKind, text, date }
    send: { accountId, peerId, text }
    Account and peer identifiers are decimal strings. The message event requires its own permission. A send handler may return replacement text, false to consume it, or nothing to leave it unchanged. A Promise from send never delays sending.

    Commands
    aorus.commands.register('name', (args, context) => result, { description, usage })
    aorus.commands.setPrefix('.')
    A synchronous string replaces the typed command. A Promise consumes the command and sends a string result after it resolves. Context contains peerId, accountId, raw and command.

    Messages and chats
    peerId and accountId values are decimal strings so 64-bit identifiers remain exact.
    await aorus.messages.send(peerId, text)
    await aorus.chats.resolve('username')
    await aorus.chats.get(peerId)
    await aorus.chats.open(peerId)
    await aorus.account.current()
    Use 'me' as peerId for Saved Messages. Sending always uses the active account; a mismatched accountId is rejected.

    Storage and settings
    aorus.storage.get(key)
    aorus.storage.set(key, value)
    aorus.storage.remove(key)
    aorus.storage.keys()
    aorus.storage.clear()
    aorus.settings.define([{ key: 'enabled', type: 'toggle', title: 'Enabled', default: true }])
    aorus.settings.get(key)
    aorus.settings.set(key, value)
    aorus.settings.all()
    Field types are toggle, text, multiline, number and select. number accepts min/max; select accepts options: [{ value, title }]. Values must be JSON-compatible.

    Network
    await aorus.http.fetch(url, { method: 'GET', headers: {}, timeout: 30000 })
    Requests use an isolated cookie-free session. Local networks, loopback, AorusGram control-plane domains and redirects to them are blocked.
    The response exposes status, ok, url, headers, text() and json(). Methods: GET, HEAD, POST, PUT, PATCH and DELETE. Authorization is stripped on cross-origin redirects.

    UI
    aorus.ui.toast(text)
    await aorus.ui.alert(title, text)
    await aorus.ui.confirm(title, text)
    await aorus.ui.prompt(title, text)
    aorus.ui.haptic('light')

    Clipboard
    await aorus.clipboard.read()
    aorus.clipboard.write(text)

    Utilities
    await aorus.util.sleep(milliseconds)
    aorus.crypto.sha256(text)
    aorus.crypto.hmacSHA256(key, text)
    aorus.crypto.randomUUID()
    aorus.crypto.randomBytes(count)
    aorus.crypto.base64Encode(text) / base64Decode(text)
    console.log/info/warn/error/debug, setTimeout, setInterval and timer cancellation are available.

    Security
    Imported plugins always start disabled. Grants belong to this installation, are never exported, and are revoked after every source edit. There is no plugin API for the file system, Keychain, licensing, AorusAI, VLESS, proxy configuration or private AorusGram domains.

    Limits
    Source: 512 KB. Storage: 1 MB. HTTP response: 5 MB. A JavaScript entry is terminated after 3 seconds. Up to 64 timers and 32 pending host requests are allowed per plugin.
    """
    }
}

private final class AorusPluginCell: UITableViewCell {
    var onToggle: ((Bool) -> Void)?; private let toggle = UISwitch()
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) { super.init(style: .subtitle, reuseIdentifier: reuseIdentifier); accessoryView = toggle; toggle.addTarget(self, action: #selector(changed), for: .valueChanged); selectionStyle = .default }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(manifest: AorusPluginManifest, theme: PresentationTheme) { textLabel?.text = manifest.name; detailTextLabel?.text = manifest.summary.isEmpty ? manifest.version : manifest.summary; textLabel?.textColor = theme.list.itemPrimaryTextColor; detailTextLabel?.textColor = theme.list.itemSecondaryTextColor; imageView?.image = UIImage(systemName: AorusPluginIcon.normalized(manifest.icon)); imageView?.tintColor = pluginColor(manifest.accent); toggle.isOn = manifest.isEnabled }
    @objc private func changed() { onToggle?(toggle.isOn) }
}

private final class AorusPluginsEmptyView: UIView {
    var onCreate: (() -> Void)?; private let icon = UIImageView(image: UIImage(systemName: "puzzlepiece.extension")); private let title = UILabel(); private let body = UILabel(); private let button = UIButton(type: .system)
    override init(frame: CGRect) { super.init(frame: frame); icon.contentMode = .scaleAspectFit; title.font = .systemFont(ofSize: 22, weight: .semibold); title.textAlignment = .center; body.font = .systemFont(ofSize: 15); body.numberOfLines = 0; body.textAlignment = .center; button.setTitle(AorusPluginUIString.create.text, for: .normal); button.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold); button.addTarget(self, action: #selector(create), for: .touchUpInside); [icon,title,body,button].forEach(addSubview) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(theme: PresentationTheme) { backgroundColor = theme.list.blocksBackgroundColor; icon.tintColor = theme.list.itemAccentColor; title.textColor = theme.list.itemPrimaryTextColor; body.textColor = theme.list.itemSecondaryTextColor; title.text = AorusPluginUIString.emptyTitle.text; body.text = AorusPluginUIString.emptyBody.text }
    override func layoutSubviews() { super.layoutSubviews(); let width = min(bounds.width - 64, 360); icon.frame = CGRect(x: (bounds.width - 52)/2, y: max(60, bounds.midY - 130), width: 52, height: 52); title.frame = CGRect(x: (bounds.width-width)/2, y: icon.frame.maxY+18, width: width, height: 30); body.frame = CGRect(x: (bounds.width-width)/2, y: title.frame.maxY+8, width: width, height: 44); button.frame = CGRect(x: (bounds.width-220)/2, y: body.frame.maxY+16, width: 220, height: 44) }
    @objc private func create() { onCreate?() }
}

// The permission names and what each one lets a plugin do. This is the text someone reads
// before granting a script access to their account, so it goes through the shared table like
// everything else: the one screen where an untranslated line would matter most.
private func permissionTitle(_ permission: AorusPluginPermission) -> String {
    switch permission {
    case .network: return aorusL("Доступ к сети", "Network")
    case .sendMessages: return aorusL("Отправка сообщений", "Send messages")
    case .chatMetadata: return aorusL("Данные чатов", "Read chat metadata")
    case .openChats: return aorusL("Открытие чатов", "Open chats")
    case .accountProfile: return aorusL("Профиль текущего аккаунта", "Read current profile")
    case .dialogs: return aorusL("Диалоги и уведомления", "Show dialogs")
    case .clipboardRead: return aorusL("Чтение буфера обмена", "Read clipboard")
    case .clipboardWrite: return aorusL("Запись в буфер обмена", "Write clipboard")
    case .incomingMessages: return aorusL("События входящих сообщений", "Receive message events")
    case .outgoingMessages: return aorusL("Обработка исходящих сообщений", "Process outgoing messages")
    }
}

private func permissionDescription(_ permission: AorusPluginPermission, requested: Bool) -> String {
    let marker = requested
        ? aorusL("Используется текущим кодом. ", "Used by the current source. ")
        : aorusL("Не обнаружено в текущем коде. ", "Not detected in the current source. ")
    switch permission {
    case .network:
        return marker + aorusL("Разрешает HTTPS-запросы к внешним публичным адресам.", "Allows HTTPS requests to public external hosts.")
    case .sendMessages:
        return marker + aorusL("Разрешает отправлять сообщения от текущего аккаунта.", "Allows sending messages from the current account.")
    case .chatMetadata:
        return marker + aorusL("Разрешает получать название и идентификатор чата.", "Allows reading a chat title and identifier.")
    case .openChats:
        return marker + aorusL("Разрешает открывать чаты в интерфейсе приложения.", "Allows opening chats in the app.")
    case .accountProfile:
        return marker + aorusL("Разрешает читать имя и идентификатор текущего аккаунта.", "Allows reading the current account name and identifier.")
    case .dialogs:
        return marker + aorusL("Разрешает показывать уведомления и запрашивать ввод.", "Allows notifications and input prompts.")
    case .clipboardRead:
        return marker + aorusL("Разрешает читать содержимое буфера обмена.", "Allows reading the clipboard.")
    case .clipboardWrite:
        return marker + aorusL("Разрешает изменять содержимое буфера обмена.", "Allows changing the clipboard.")
    case .incomingMessages:
        return marker + aorusL("Разрешает получать события новых сообщений.", "Allows receiving new-message events.")
    case .outgoingMessages:
        return marker + aorusL("Разрешает изменять или отменять отправляемый текст.", "Allows changing or consuming outgoing text.")
    }
}

private func pluginColor(_ value: String) -> UIColor {
    let hex = AorusPluginAccent.normalized(value)
    guard let rgb = UInt32(hex, radix: 16) else { return .systemPurple }
    return UIColor(
        red: CGFloat((rgb >> 16) & 0xff) / 255.0,
        green: CGFloat((rgb >> 8) & 0xff) / 255.0,
        blue: CGFloat(rgb & 0xff) / 255.0,
        alpha: 1.0
    )
}
