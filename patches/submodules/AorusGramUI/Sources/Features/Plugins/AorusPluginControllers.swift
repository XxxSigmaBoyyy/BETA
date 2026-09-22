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
    case status, running, stopped, failed, diagnostics, commands, events, noCommands
    case isolation, available, unavailable, granted, outgoingHook, active, inactive, customColor
    case sourceChangedDisabled, consoleEmpty

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
        case .status: return aorusL("Состояние", "Status")
        case .running: return aorusL("Работает", "Running")
        case .stopped: return aorusL("Остановлен", "Stopped")
        case .failed: return aorusL("Сбой", "Failed")
        case .diagnostics: return aorusL("Диагностика", "Diagnostics")
        case .commands: return aorusL("Команды", "Commands")
        case .events: return aorusL("События", "Events")
        case .noCommands: return aorusL("Плагин не зарегистрировал команд", "The plugin registered no commands")
        case .isolation: return aorusL("Изоляция выполнения", "Execution isolation")
        case .available: return aorusL("Доступна", "Available")
        case .unavailable: return aorusL("Недоступна", "Unavailable")
        case .granted: return aorusL("Выдано", "Granted")
        case .outgoingHook: return aorusL("Перехват исходящих", "Outgoing interception")
        case .active: return aorusL("Активен", "Active")
        case .inactive: return aorusL("Неактивен", "Inactive")
        case .customColor: return aorusL("Свой цвет", "Custom color")
        case .sourceChangedDisabled: return aorusL("Код изменился, поэтому плагин выключен, а выданные разрешения отозваны.", "The code changed, so the plugin was switched off and the permissions it had were revoked.")
        case .consoleEmpty: return aorusL("Пока пусто. Здесь появится всё, что плагин пишет через console, и всё, что приложение сообщает о нём.", "Nothing yet. Everything the plugin writes through console, and everything the app reports about it, appears here.")
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

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

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
        aorus.ui.definePages([{
          id: 'home', title: 'My plugin', sections: [{
            rows: [{ id: 'hello', type: 'button', title: 'Say hello', icon: 'hand.wave.fill' }]
          }]
        }]);

        aorus.integrations.settings.register({
          id: 'home', title: 'My plugin', icon: 'puzzlepiece.extension',
          pageId: 'home', placement: 'plugins'
        });

        aorus.on('uiAction', function (event) {
          if (event.pageId === 'home' && event.rowId === 'hello') {
            aorus.ui.toast('Hello!');
          }
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

    func numberOfSections(in tableView: UITableView) -> Int { 1 }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { manifests.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "plugin", for: indexPath) as! AorusPluginCell
        let manifest = manifests[indexPath.row]
        cell.configure(manifest: manifest, record: AorusPluginStore.shared.load(id: manifest.id), theme: presentationData.theme)
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
        let lines = requested.sorted { $0.rawValue < $1.rawValue }.map { "- \(permissionTitle($0))" }
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

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        reload()
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

    /// The screens this plugin has. Settings is only here when the plugin declared some:
    /// a row that always opens an empty list teaches people the feature is broken.
    private enum Screen {
        case appearance
        case editor
        case console
        case settings
        case permissions
        case documentation
    }

    private var screens: [Screen] {
        var result: [Screen] = [.appearance, .editor, .console]
        if !AorusPluginRuntimeManager.shared.settingsSchema(id: record.manifest.id).isEmpty {
            result.append(.settings)
        }
        result.append(contentsOf: [.permissions, .documentation])
        return result
    }

    private func title(for screen: Screen) -> String {
        switch screen {
        case .appearance: return AorusPluginUIString.configure.text
        case .editor: return AorusPluginUIString.editCode.text
        case .console: return AorusPluginUIString.console.text
        case .settings: return AorusPluginUIString.settings.text
        case .permissions: return AorusPluginUIString.permissions.text
        case .documentation: return AorusPluginUIString.documentation.text
        }
    }

    func numberOfSections(in tableView: UITableView) -> Int { 3 }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch section {
        case 0: return 2
        case 1: return screens.count
        default: return 3
        }
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        cell.backgroundColor = presentationData.theme.list.itemBlocksBackgroundColor
        cell.textLabel?.textColor = presentationData.theme.list.itemPrimaryTextColor
        if indexPath.section == 0 {
            let toggle = UISwitch()
            if indexPath.row == 0 { cell.textLabel?.text = AorusPluginUIString.enabled.text; toggle.isOn = record.manifest.isEnabled; toggle.addTarget(self, action: #selector(enabledChanged(_:)), for: .valueChanged) }
            else { cell.textLabel?.text = AorusPluginUIString.autostart.text; toggle.isOn = record.manifest.autostart; toggle.addTarget(self, action: #selector(autostartChanged(_:)), for: .valueChanged) }
            cell.accessoryView = toggle
            cell.selectionStyle = .none
        } else if indexPath.section == 1 {
            cell.textLabel?.text = title(for: screens[indexPath.row]); cell.accessoryType = .disclosureIndicator
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
            switch screens[indexPath.row] {
            case .appearance: (navigationController as? NavigationController)?.pushViewController(AorusPluginMetadataController(context: context, record: record))
            case .editor: (navigationController as? NavigationController)?.pushViewController(AorusPluginEditorController(context: context, record: record))
            case .console: (navigationController as? NavigationController)?.pushViewController(AorusPluginConsoleController(context: context, record: record))
            case .settings: (navigationController as? NavigationController)?.pushViewController(AorusPluginSettingsController(context: context, record: record))
            case .permissions: (navigationController as? NavigationController)?.pushViewController(AorusPluginPermissionsController(context: context, record: record))
            case .documentation: (navigationController as? NavigationController)?.pushViewController(AorusPluginDocsController(context: context))
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
        if indexPath.section == 0 {
            if indexPath.row == 1 {
                (navigationController as? NavigationController)?.pushViewController(AorusPluginLongTextController(
                    presentationData: presentationData,
                    title: AorusPluginUIString.description.text,
                    text: record.manifest.summary,
                    saved: { [weak self] value in self?.record.manifest.summary = value; self?.persist() }
                ))
            } else {
                editText(row: indexPath.row)
            }
            return
        }
        if indexPath.row == 0 {
            (navigationController as? NavigationController)?.pushViewController(AorusPluginVisualPickerController(
                presentationData: presentationData,
                mode: .icons(accent: record.manifest.accent),
                selected: record.manifest.icon,
                changed: { [weak self] value in self?.record.manifest.icon = value; self?.persist() }
            ))
        } else {
            (navigationController as? NavigationController)?.pushViewController(AorusPluginVisualPickerController(
                presentationData: presentationData,
                mode: .colors(icon: record.manifest.icon),
                selected: record.manifest.accent,
                changed: { [weak self] value in self?.record.manifest.accent = value; self?.persist() }
            ))
        }
    }

    private func editText(row: Int) {
        guard row != 1 else { return }
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

private final class AorusPluginLongTextController: ViewController {
    private let presentationData: PresentationData
    private let textView = UITextView()
    private let saved: (String) -> Void
    private let maxLength: Int

    init(presentationData: PresentationData, title: String, text: String, maxLength: Int = 2_000, saved: @escaping (String) -> Void) {
        self.presentationData = presentationData
        self.saved = saved
        self.maxLength = max(1, maxLength)
        super.init(navigationBarPresentationData: NavigationBarPresentationData(presentationData: presentationData, style: .glass))
        self.title = title
        textView.text = text
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: AorusPluginUIString.save.text, style: .done, target: self, action: #selector(save))
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadDisplayNode() {
        displayNode = ViewControllerTracingNode()
        displayNode.backgroundColor = presentationData.theme.list.blocksBackgroundColor
        textView.backgroundColor = presentationData.theme.list.itemBlocksBackgroundColor
        textView.textColor = presentationData.theme.list.itemPrimaryTextColor
        textView.tintColor = presentationData.theme.list.itemAccentColor
        textView.font = .systemFont(ofSize: 17)
        textView.layer.cornerRadius = 12
        textView.layer.cornerCurve = .continuous
        textView.textContainerInset = UIEdgeInsets(top: 14, left: 12, bottom: 14, right: 12)
        textView.keyboardDismissMode = .interactive
        displayNode.view.addSubview(textView)
        displayNodeDidLoad()
        DispatchQueue.main.async { [weak self] in self?.textView.becomeFirstResponder() }
    }

    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        let top = navigationLayout(layout: layout).navigationFrame.maxY
        transition.updateFrame(view: textView, frame: CGRect(x: 16, y: top + 16, width: layout.size.width - 32, height: max(160, layout.size.height - top - layout.intrinsicInsets.bottom - 32)))
    }

    @objc private func save() {
        saved(String((textView.text ?? "").prefix(maxLength)).trimmingCharacters(in: .whitespacesAndNewlines))
        _ = navigationController?.popViewController(animated: true)
    }
}

private final class AorusPluginVisualPickerController: ViewController, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    enum Mode {
        case icons(accent: String)
        case colors(icon: String)
    }

    private let presentationData: PresentationData
    private let mode: Mode
    private var selected: String
    private let changed: (String) -> Void
    private let collectionView: UICollectionView
    private let preview = UIView()
    private let previewIcon = UIImageView()
    private var colorPickerDelegate: AnyObject?

    init(presentationData: PresentationData, mode: Mode, selected: String, changed: @escaping (String) -> Void) {
        self.presentationData = presentationData
        self.mode = mode
        self.selected = selected
        self.changed = changed
        let layout = UICollectionViewFlowLayout()
        layout.minimumLineSpacing = 12
        layout.minimumInteritemSpacing = 12
        layout.sectionInset = UIEdgeInsets(top: 20, left: 20, bottom: 30, right: 20)
        self.collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(navigationBarPresentationData: NavigationBarPresentationData(presentationData: presentationData, style: .glass))
        switch mode {
        case .icons: title = AorusPluginUIString.icon.text
        case .colors:
            title = AorusPluginUIString.accent.text
            navigationItem.rightBarButtonItem = UIBarButtonItem(
                title: AorusPluginUIString.customColor.text,
                style: .plain,
                target: self,
                action: #selector(chooseCustomColor)
            )
        }
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadDisplayNode() {
        displayNode = ViewControllerTracingNode()
        displayNode.backgroundColor = presentationData.theme.list.blocksBackgroundColor
        collectionView.backgroundColor = .clear
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(AorusPluginPickerCell.self, forCellWithReuseIdentifier: "choice")
        preview.layer.cornerRadius = 22
        preview.layer.cornerCurve = .continuous
        previewIcon.contentMode = .center
        previewIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 34, weight: .semibold)
        preview.addSubview(previewIcon)
        displayNode.view.addSubview(preview)
        displayNode.view.addSubview(collectionView)
        updatePreview()
        displayNodeDidLoad()
    }

    /// The tile as it will look, in the colour and with the glyph being chosen. Choosing a
    /// colour from a grid of squares tells you nothing about the icon it will carry.
    private func updatePreview() {
        let color: UIColor
        let icon: String
        switch mode {
        case let .icons(accent):
            color = pluginColor(accent)
            icon = selected
        case let .colors(current):
            color = pluginColor(selected)
            icon = current
        }
        preview.backgroundColor = color.withAlphaComponent(0.16)
        previewIcon.image = UIImage(systemName: AorusPluginIcon.normalized(icon))
        previewIcon.tintColor = color
    }

    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        let top = navigationLayout(layout: layout).navigationFrame.maxY
        let previewSide: CGFloat = 84
        transition.updateFrame(view: preview, frame: CGRect(x: (layout.size.width - previewSide) / 2, y: top + 18, width: previewSide, height: previewSide))
        previewIcon.frame = preview.bounds
        let gridTop = top + 18 + previewSide + 18
        transition.updateFrame(view: collectionView, frame: CGRect(x: 0, y: gridTop, width: layout.size.width, height: max(0, layout.size.height - gridTop)))
    }

    @objc private func chooseCustomColor() {
        guard #available(iOS 14.0, *) else {
            promptHexColor()
            return
        }
        let picker = UIColorPickerViewController()
        picker.selectedColor = pluginColor(selected)
        picker.supportsAlpha = false
        let delegate = AorusPluginColorPickerDelegate { [weak self] color in
            guard let self else { return }
            self.apply(AorusPluginAccent.normalized(aorusHexString(color)))
        }
        colorPickerDelegate = delegate
        picker.delegate = delegate
        present(picker, animated: true)
    }

    /// iOS 13 has no system colour picker, and a feature that simply vanishes on an older
    /// phone is not a feature. Six hex digits reach the same place.
    private func promptHexColor() {
        let alert = UIAlertController(title: AorusPluginUIString.customColor.text, message: "RRGGBB", preferredStyle: .alert)
        alert.addTextField { field in
            field.text = self.selected
            field.autocapitalizationType = .allCharacters
        }
        alert.addAction(UIAlertAction(title: presentationData.strings.Common_Cancel, style: .cancel))
        alert.addAction(UIAlertAction(title: AorusPluginUIString.save.text, style: .default) { [weak self, weak alert] _ in
            guard let self, let value = alert?.textFields?.first?.text else { return }
            self.apply(AorusPluginAccent.normalized(value))
        })
        present(alert, animated: true)
    }

    private func apply(_ value: String) {
        selected = value
        changed(value)
        collectionView.reloadData()
        updatePreview()
        UISelectionFeedbackGenerator().selectionChanged()
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { items.count }
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "choice", for: indexPath) as! AorusPluginPickerCell
        let value = items[indexPath.item]
        switch mode {
        case let .icons(accent): cell.configure(icon: value, color: pluginColor(accent), selected: value == selected)
        case let .colors(icon): cell.configure(icon: icon, color: pluginColor(value), selected: value == selected, filled: true)
        }
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        apply(items[indexPath.item])
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        let columns: CGFloat = 4
        let width = floor((collectionView.bounds.width - 40 - 12 * (columns - 1)) / columns)
        return CGSize(width: width, height: width)
    }

    private var items: [String] {
        switch mode {
        case .icons:
            return AorusPluginIcon.all
        case .colors:
            var values = AorusPluginAccent.all
            if !values.contains(selected) { values.insert(selected, at: 0) }
            return values
        }
    }
}

private final class AorusPluginPickerCell: UICollectionViewCell {
    private let background = UIView()
    private let icon = UIImageView()
    private let check = UIImageView(image: UIImage(systemName: "checkmark.circle.fill"))

    override init(frame: CGRect) {
        super.init(frame: frame)
        background.layer.cornerRadius = 16
        background.layer.cornerCurve = .continuous
        icon.contentMode = .center
        check.tintColor = .white
        contentView.addSubview(background)
        contentView.addSubview(icon)
        contentView.addSubview(check)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(icon name: String?, color: UIColor, selected: Bool, filled: Bool = false) {
        background.backgroundColor = filled ? color : color.withAlphaComponent(0.16)
        // `map` over an optional name would wrap the already-optional image again.
        icon.image = name.flatMap { UIImage(systemName: $0) }
        icon.tintColor = filled ? .white : color
        check.isHidden = !selected
        contentView.layer.borderWidth = selected ? 2 : 0
        contentView.layer.borderColor = color.cgColor
        contentView.layer.cornerRadius = 18
        contentView.layer.cornerCurve = .continuous
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        background.frame = contentView.bounds.insetBy(dx: 5, dy: 5)
        icon.frame = contentView.bounds
        check.frame = CGRect(x: contentView.bounds.maxX - 27, y: 7, width: 20, height: 20)
    }
}

private final class AorusPluginEditorController: ViewController, UITextViewDelegate {
    private let context: AccountContext
    private let presentationData: PresentationData
    private var record: AorusPluginRecord
    private let editor = UITextView()
    private let lineNumbers = UITextView()
    private let console = UITextView()
    private let consolePlaceholder = UILabel()
    private let editorTools = UIStackView()
    private weak var observedSandbox: AorusPluginSandbox?
    private var runAfterReview = false
    private var licenseObserver: NSObjectProtocol?
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

    deinit {
        highlightWork?.cancel()
        observedSandbox?.observeLog(nil)
        if let licenseObserver { NotificationCenter.default.removeObserver(licenseObserver) }
    }

    override func loadDisplayNode() {
        displayNode = ViewControllerTracingNode()
        let dark = presentationData.theme.overallDarkAppearance
        let background = dark ? UIColor(red: 0.055, green: 0.059, blue: 0.071, alpha: 1) : UIColor(red: 0.96, green: 0.97, blue: 0.98, alpha: 1)
        displayNode.backgroundColor = background
        lineNumbers.font = .monospacedSystemFont(ofSize: 13, weight: .regular); lineNumbers.textColor = .secondaryLabel; lineNumbers.textAlignment = .right; lineNumbers.backgroundColor = .clear; lineNumbers.isEditable = false; lineNumbers.isSelectable = false; lineNumbers.isUserInteractionEnabled = false; lineNumbers.textContainerInset = UIEdgeInsets(top: 14, left: 0, bottom: 80, right: 2); lineNumbers.textContainer.lineFragmentPadding = 0
        editor.backgroundColor = .clear; editor.textColor = dark ? .white : .black; editor.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        editor.autocorrectionType = .no; editor.autocapitalizationType = .none; editor.smartQuotesType = .no; editor.smartDashesType = .no
        editor.textContainerInset = UIEdgeInsets(top: 14, left: 8, bottom: 80, right: 12); editor.delegate = self; editor.text = record.source
        console.backgroundColor = background; console.textColor = dark ? UIColor(white: 0.86, alpha: 1) : .darkText; console.font = .monospacedSystemFont(ofSize: 12, weight: .regular); console.isEditable = false; console.isHidden = true
        console.layer.borderColor = UIColor.separator.cgColor; console.layer.borderWidth = 1 / UIScreen.main.scale
        console.textContainerInset = UIEdgeInsets(top: 42, left: 16, bottom: 12, right: 16)
        consolePlaceholder.text = AorusPluginUIString.console.text
        consolePlaceholder.font = .systemFont(ofSize: 13, weight: .semibold)
        consolePlaceholder.textColor = .secondaryLabel
        consolePlaceholder.isHidden = true
        editorTools.axis = .horizontal; editorTools.distribution = .fillEqually; editorTools.backgroundColor = dark ? UIColor(white: 0.12, alpha: 0.94) : UIColor(white: 1, alpha: 0.96)
        addTool(AorusPluginUIString.run.text, "play.fill", #selector(runPlugin)); addTool(AorusPluginUIString.stop.text, "stop.fill", #selector(stopPlugin)); addTool(AorusPluginUIString.console.text, "terminal.fill", #selector(toggleConsole)); addTool(AorusPluginUIString.documentation.text, "book.fill", #selector(openDocs))
        displayNode.view.addSubview(lineNumbers); displayNode.view.addSubview(editor); displayNode.view.addSubview(console); displayNode.view.addSubview(consolePlaceholder); displayNode.view.addSubview(editorTools)
        licenseObserver = NotificationCenter.default.addObserver(forName: Notification.Name("aorusgram.licenseLockChanged"), object: nil, queue: .main) { [weak self] _ in
            guard !AorusLicenseAccess.isAllowed else { return }
            self?.stopPlugin()
        }
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
        transition.updateFrame(view: consolePlaceholder, frame: CGRect(x: 20, y: layout.size.height - toolbarHeight - consoleHeight + 12, width: layout.size.width - 40, height: 22))
        transition.updateFrame(view: editorTools, frame: CGRect(x: 0, y: layout.size.height - toolbarHeight, width: layout.size.width, height: toolbarHeight))
    }

    private func addTool(_ title: String, _ image: String, _ action: Selector) { let button = UIButton(type: .system); button.setImage(UIImage(systemName: image), for: .normal); button.setTitle(" " + title, for: .normal); button.titleLabel?.font = .systemFont(ofSize: 12, weight: .semibold); button.addTarget(self, action: action, for: .touchUpInside); editorTools.addArrangedSubview(button) }

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
            }
            try AorusPluginStore.shared.save(record)
            if let saved = AorusPluginStore.shared.load(id: record.manifest.id) {
                record = saved
            }
            title = record.manifest.name
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            // New or changed code never inherits grants. Review it immediately after save,
            // including the first save, so a freshly-created command cannot look enabled
            // while the secure runtime has correctly refused to start it.
            if sourceChanged, !record.manifest.isEnabled {
                offerReenable()
            }
        } catch {
            appendConsole("ERROR: \(error.localizedDescription)")
        }
    }

    private func offerReenable() {
        let requested = AorusPluginPermission.requestedBySource(record.source)
        let lines = requested.sorted { $0.rawValue < $1.rawValue }.map { permissionTitle($0) }
        let detail = lines.isEmpty ? AorusPluginUIString.noPermissions.text : lines.joined(separator: "\n")
        let alert = UIAlertController(
            title: AorusPluginUIString.reviewPermissions.text,
            message: AorusPluginUIString.sourceChangedDisabled.text + "\n\n" + detail,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: presentationData.strings.Common_Cancel, style: .cancel) { [weak self] _ in self?.runAfterReview = false })
        alert.addAction(UIAlertAction(title: AorusPluginUIString.grantAndEnable.text, style: .default) { [weak self] _ in
            guard let self else { return }
            do {
                try AorusPluginStore.shared.setPermissionState(
                    AorusPluginPermissionState(sourceDigest: AorusPluginStore.sourceDigest(self.record.source), granted: requested),
                    for: self.record.manifest.id
                )
                var manifest = self.record.manifest
                manifest.isEnabled = true
                try AorusPluginStore.shared.updateManifest(manifest)
                self.record.manifest = manifest
                AorusPluginRuntimeManager.shared.start(id: manifest.id) { [weak self] error in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        if self.runAfterReview {
                            self.runAfterReview = false
                            self.attachLiveRuntime(error: error)
                        } else if let error { self.appendConsole(error.message) }
                    }
                }
            } catch {
                self.appendConsole("ERROR: \(error.localizedDescription)")
            }
        })
        present(alert, animated: true)
    }

    @objc private func runPlugin() {
        guard AorusLicenseAccess.isAllowed else {
            appendConsole("Plugin execution is unavailable")
            return
        }
        let source = editor.text ?? ""
        let diagnostics = AorusPluginSandbox.checkSyntax(source)
        guard diagnostics.isEmpty else { appendConsole("Line \(diagnostics[0].line): \(diagnostics[0].message)"); return }
        console.isHidden = false
        console.text = ""
        updateConsolePlaceholder()
        updateLayout(animated: true)
        if source != record.source {
            runAfterReview = true
            save()
            return
        }
        if !record.manifest.isEnabled {
            runAfterReview = true
            offerReenable()
            return
        }
        observedSandbox?.observeLog(nil)
        AorusPluginRuntimeManager.shared.restart(id: record.manifest.id) { [weak self] error in
            DispatchQueue.main.async { self?.attachLiveRuntime(error: error) }
        }
    }

    private func attachLiveRuntime(error: AorusPluginRunError?) {
        guard let sandbox = AorusPluginRuntimeManager.shared.sandbox(id: record.manifest.id), error == nil else {
            appendConsole(error?.message ?? AorusPluginRunError.notRunning.message)
            return
        }
        observedSandbox = sandbox
        sandbox.observeLog { [weak self] entry in
            DispatchQueue.main.async { self?.appendConsole("[\(entry.level.rawValue)] \(entry.text)") }
        }
    }

    @objc private func stopPlugin() {
        observedSandbox?.observeLog(nil)
        observedSandbox = nil
        AorusPluginRuntimeManager.shared.stop(id: record.manifest.id)
    }
    @objc private func toggleConsole() { console.isHidden.toggle(); updateConsolePlaceholder(); updateLayout(animated: true) }
    @objc private func openDocs() { (navigationController as? NavigationController)?.pushViewController(AorusPluginDocsController(context: context)) }
    @objc private func editMetadata() {
        (navigationController as? NavigationController)?.pushViewController(AorusPluginMetadataController(context: context, record: record))
    }
    private func appendConsole(_ text: String) { console.text += (console.text.isEmpty ? "" : "\n") + text; updateConsolePlaceholder(); console.scrollRangeToVisible(NSRange(location: max(0, console.text.count - 1), length: 1)) }
    private func updateConsolePlaceholder() { consolePlaceholder.isHidden = console.isHidden || !console.text.isEmpty }
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
    private let emptyLabel = UILabel()
    private var schemaSandbox: AorusPluginSandbox?
    private var schemaObserver: NSObjectProtocol?
    private var valuesObserver: NSObjectProtocol?
    private var licenseObserver: NSObjectProtocol?
    private var colorPickerDelegate: AnyObject?
    init(context: AccountContext, record: AorusPluginRecord) { self.context = context; self.record = record; self.presentationData = context.sharedContext.currentPresentationData.with { $0 }; self.values = AorusPluginStore.shared.settings(for: record.manifest.id); super.init(navigationBarPresentationData: NavigationBarPresentationData(presentationData: presentationData, style: .glass)); title = AorusPluginUIString.settings.text; fields = AorusPluginRuntimeManager.shared.settingsSchema(id: record.manifest.id) }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit {
        if let schemaObserver { NotificationCenter.default.removeObserver(schemaObserver) }
        if let valuesObserver { NotificationCenter.default.removeObserver(valuesObserver) }
        if let licenseObserver { NotificationCenter.default.removeObserver(licenseObserver) }
        schemaSandbox?.stop()
    }
    override func loadDisplayNode() {
        displayNode = ViewControllerTracingNode(); displayNode.backgroundColor = presentationData.theme.list.blocksBackgroundColor
        tableView.backgroundColor = presentationData.theme.list.blocksBackgroundColor; tableView.dataSource = self; tableView.delegate = self
        emptyLabel.text = aorusL("У этого плагина нет настраиваемых параметров.", "This plugin has no configurable settings.")
        emptyLabel.textColor = presentationData.theme.list.itemSecondaryTextColor
        emptyLabel.font = .systemFont(ofSize: 15)
        emptyLabel.textAlignment = .center
        emptyLabel.numberOfLines = 0
        tableView.backgroundView = emptyLabel
        displayNode.view.addSubview(tableView)
        schemaObserver = NotificationCenter.default.addObserver(forName: Notification.Name("aorusgram.plugins.schemaChanged"), object: nil, queue: .main) { [weak self] note in
            guard let self, note.object as? String == self.record.manifest.id else { return }
            self.reloadSchema()
        }
        valuesObserver = NotificationCenter.default.addObserver(forName: Notification.Name("aorusgram.plugins.settingsChanged"), object: nil, queue: .main) { [weak self] note in
            guard let self, note.object as? String == self.record.manifest.id else { return }
            self.values = AorusPluginStore.shared.settings(for: self.record.manifest.id)
            self.tableView.reloadData()
        }
        licenseObserver = NotificationCenter.default.addObserver(forName: Notification.Name("aorusgram.licenseLockChanged"), object: nil, queue: .main) { [weak self] _ in
            guard !AorusLicenseAccess.isAllowed else { return }
            self?.schemaSandbox?.stop()
            self?.schemaSandbox = nil
        }
        refreshEmptyState()
        if fields.isEmpty, AorusLicenseAccess.isAllowed { discoverSchema() }
        displayNodeDidLoad()
    }
    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) { super.containerLayoutUpdated(layout, transition: transition); let top = navigationLayout(layout: layout).navigationFrame.maxY; transition.updateFrame(view: tableView, frame: CGRect(x: 0, y: top, width: layout.size.width, height: layout.size.height - top)) }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { fields.count }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let field = fields[indexPath.row]
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.text = field.title
        cell.detailTextLabel?.text = displayValue(for: field) ?? field.summary
        if field.kind == .section {
            cell.textLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
            cell.textLabel?.textColor = .secondaryLabel
            cell.selectionStyle = .none
        } else if field.kind == .toggle {
            let toggle = UISwitch()
            toggle.isOn = values[field.key]?.boolValue ?? field.defaultValue?.boolValue ?? false
            toggle.tag = indexPath.row
            toggle.addTarget(self, action: #selector(toggleChanged(_:)), for: .valueChanged)
            cell.accessoryView = toggle
            cell.selectionStyle = .none
        } else if field.kind == .slider {
            let slider = UISlider(frame: CGRect(x: 0, y: 0, width: 142, height: 32))
            slider.minimumValue = Float(field.minimum ?? 0)
            slider.maximumValue = Float(field.maximum ?? 100)
            slider.value = Float(values[field.key]?.doubleValue ?? field.defaultValue?.doubleValue ?? field.minimum ?? 0)
            slider.tag = indexPath.row
            slider.addTarget(self, action: #selector(sliderChanged(_:)), for: [.touchUpInside, .touchUpOutside])
            cell.accessoryView = slider
            cell.selectionStyle = .none
        } else if field.kind == .stepper {
            let stepper = UIStepper()
            stepper.minimumValue = field.minimum ?? 0
            stepper.maximumValue = field.maximum ?? 100
            stepper.stepValue = field.step ?? 1
            stepper.value = values[field.key]?.doubleValue ?? field.defaultValue?.doubleValue ?? field.minimum ?? 0
            stepper.tag = indexPath.row
            stepper.addTarget(self, action: #selector(stepperChanged(_:)), for: .valueChanged)
            cell.accessoryView = stepper
            cell.selectionStyle = .none
        } else if field.kind == .colorPicker {
            let swatch = UIView(frame: CGRect(x: 0, y: 0, width: 26, height: 26))
            swatch.layer.cornerRadius = 7
            swatch.backgroundColor = pluginColor((values[field.key] ?? field.defaultValue)?.stringValue ?? AorusPluginAccent.fallback)
            cell.accessoryView = swatch
        } else if field.kind == .button || field.kind == .reset {
            cell.textLabel?.textColor = presentationData.theme.list.itemAccentColor
        } else {
            cell.accessoryType = .disclosureIndicator
        }
        return cell
    }
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let field = fields[indexPath.row]
        guard field.kind != .toggle && field.kind != .slider && field.kind != .stepper && field.kind != .section else { return }
        if field.kind == .button {
            AorusPluginRuntimeManager.shared.sandbox(id: record.manifest.id)?.dispatch(event: "settings.action", payload: ["pluginId": record.manifest.id, "key": field.key])
            return
        }
        if field.kind == .reset {
            do {
                try AorusPluginStore.shared.setSettings([:], for: record.manifest.id)
                values = [:]
                if let sandbox = AorusPluginRuntimeManager.shared.sandbox(id: record.manifest.id) {
                    sandbox.updateSettings([:])
                    sandbox.dispatch(event: "settings.reset", payload: ["pluginId": record.manifest.id])
                }
                tableView.reloadData()
            } catch { showSettingsError(error) }
            return
        }
        if field.kind == .colorPicker, #available(iOS 14.0, *) {
            let picker = UIColorPickerViewController()
            picker.supportsAlpha = false
            picker.selectedColor = pluginColor((values[field.key] ?? field.defaultValue)?.stringValue ?? AorusPluginAccent.fallback)
            let delegate = AorusPluginColorPickerDelegate { [weak self] color in
                self?.store(.string("#" + aorusHexString(color)), field: field, indexPath: indexPath)
            }
            colorPickerDelegate = delegate
            picker.delegate = delegate
            present(picker, animated: true)
            return
        }
        if field.kind == .multiline {
            let text = values[field.key]?.stringValue ?? field.defaultValue?.stringValue ?? ""
            (navigationController as? NavigationController)?.pushViewController(AorusPluginLongTextController(
                presentationData: presentationData,
                title: field.title,
                text: text,
                maxLength: 16_384,
                saved: { [weak self] value in self?.store(.string(value), field: field, indexPath: indexPath) }
            ))
            return
        }
        if field.kind == .select || field.kind == .multiSelect {
            let sheet = UIAlertController(title: field.title, message: field.summary, preferredStyle: .actionSheet)
            for option in field.options ?? [] {
                sheet.addAction(UIAlertAction(title: option.title, style: .default) { _ in
                    if field.kind == .multiSelect {
                        let current: [AorusPluginJSONValue]
                        if case let .array(items)? = self.values[field.key] ?? field.defaultValue { current = items } else { current = [] }
                        let selected = AorusPluginJSONValue.string(option.value)
                        self.store(.array(current.contains(selected) ? current.filter { $0 != selected } : current + [selected]), field: field, indexPath: indexPath)
                    } else { self.store(.string(option.value), field: field, indexPath: indexPath) }
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
    @objc private func toggleChanged(_ sender: UISwitch) {
        let field = fields[sender.tag]
        store(.bool(sender.isOn), field: field, indexPath: IndexPath(row: sender.tag, section: 0))
    }
    @objc private func sliderChanged(_ sender: UISlider) {
        let field = fields[sender.tag]
        let step = field.step ?? 1
        let value = (Double(sender.value) / step).rounded() * step
        store(.number(min(field.maximum ?? 100, max(field.minimum ?? 0, value))), field: field, indexPath: IndexPath(row: sender.tag, section: 0))
    }
    @objc private func stepperChanged(_ sender: UIStepper) {
        let field = fields[sender.tag]
        store(.number(sender.value), field: field, indexPath: IndexPath(row: sender.tag, section: 0))
    }
    private func displayValue(for field: AorusPluginSettingField) -> String? {
        let value = values[field.key] ?? field.defaultValue
        if let string = value?.stringValue {
            return field.options?.first(where: { $0.value == string })?.title ?? string
        }
        if let number = value?.doubleValue { return String(number) }
        if case let .array(items)? = value { return items.compactMap { $0.stringValue }.joined(separator: ", ") }
        return nil
    }
    private func store(_ value: AorusPluginJSONValue, field: AorusPluginSettingField, indexPath: IndexPath) {
        values[field.key] = value
        do {
            try AorusPluginStore.shared.setSettings(values, for: record.manifest.id)
            AorusPluginRuntimeManager.shared.sandbox(id: record.manifest.id)?.updateSettings(values)
            tableView.reloadRows(at: [indexPath], with: .none)
        } catch { showSettingsError(error) }
    }

    private func showSettingsError(_ error: Error) {
        let alert = UIAlertController(title: AorusPluginUIString.settings.text, message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    private func reloadSchema() {
        fields = AorusPluginRuntimeManager.shared.settingsSchema(id: record.manifest.id)
        refreshEmptyState()
        tableView.reloadData()
    }

    private func refreshEmptyState() {
        emptyLabel.isHidden = !fields.isEmpty
    }

    private func discoverSchema() {
        let host = AorusPluginNullHost()
        host.onSettingsSchemaChanged = { [weak self] _, fields in
            guard let self else { return }
            DispatchQueue.main.async {
                self.fields = fields
                if !fields.isEmpty {
                    try? AorusPluginStore.shared.setSchema(fields, sourceDigest: AorusPluginStore.sourceDigest(self.record.source), for: self.record.manifest.id)
                }
                self.refreshEmptyState()
                self.tableView.reloadData()
            }
        }
        let sandbox = AorusPluginSandbox(
            manifest: record.manifest,
            source: record.source,
            host: host,
            // Discovery runs against the no-op host. Grant non-network capabilities so a
            // harmless top-level UI registration before settings.define cannot leave this
            // screen empty, while never allowing the discovery pass to contact the network.
            permissions: Set(AorusPluginPermission.allCases).subtracting([.network]),
            storage: AorusPluginStore.shared.storage(for: record.manifest.id),
            settings: values
        )
        schemaSandbox = sandbox
        sandbox.start { [weak self, weak sandbox] _ in
            sandbox?.stop()
            self?.schemaSandbox = nil
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
            Каждый плагин работает в отдельном контексте JavaScriptCore. У него нет доступа к файловой системе, нативным модулям, Keychain, лицензии, внутренним компонентам AorusAI или туннелю. Опасные возможности включаются только после подтверждения, а любое изменение кода отзывает все выданные разрешения.

            Жизненный цикл
            aorus.on('start', handler)
            aorus.on('stop', handler)
            aorus.on('foreground', handler)
            aorus.on('background', handler)

            События
            aorus.on(event, handler) возвращает функцию отписки. Также доступны aorus.once и aorus.off.
            message: { accountId, peerId, senderId, msgId, msgNs, peerKind, text, date }
            messageDeleted: { accountId, peerId, msgId, msgNs }
            messageEdited: { accountId, peerId, msgId, msgNs, originalText, text, date }
            send: { accountId, peerId, text }
            Идентификаторы аккаунтов и чатов — десятичные строки. События сообщений требуют отдельного разрешения и относятся только к текущему аккаунту. Обработчик send может вернуть новую строку, false для отмены или ничего для отправки без изменений. Promise из send не задерживает отправку.

            Команды
            aorus.commands.register('name', (args, context) => result, { description, usage })
            aorus.commands.setPrefix('.')
            Синхронная строка заменяет введённую команду. Promise поглощает команду и после завершения отправляет строковый результат. Контекст содержит peerId, accountId, raw и command.

            Сообщения и чаты
            Идентификаторы peerId и accountId передаются десятичными строками без потери точности.
            await aorus.messages.send(peerId, text)
            const message = { peerId, namespace, messageId }
            await aorus.messages.edit(message, 'Новый текст')
            await aorus.messages.delete(message, { forEveryone: true })
            await aorus.messages.forward(message, destinationPeerId)
            await aorus.messages.react(message, '👍')
            await aorus.messages.react(message, null)
            await aorus.chats.resolve('username')
            await aorus.chats.get(peerId)
            await aorus.chats.history(peerId, { limit: 50 })
            await aorus.chats.open(peerId)
            await aorus.account.current()
            await aorus.telegram.openLink('tg://resolve?domain=telegram')
            Используйте 'me' вместо peerId для текущего сохранённого чата. История требует отдельного разрешения и возвращает очищенные поля id, namespace, peerId, senderId, text, date, incoming и hasMedia. Эти peerId, namespace и id образуют ссылку на сообщение для edit/delete/forward/react. Перед действием клиент проверяет наличие сообщения локально, а права на изменение проверяет Telegram. Один запрос истории ограничен 100 сообщениями и 128 000 символами. Telegram-ссылки открываются нативной навигацией. Отправка всегда выполняется только от активного аккаунта; подмена accountId отклоняется.

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

            Нативные страницы
            aorus.ui.definePages([{ id: 'main', title: 'Помощник', sections: [{ title: 'Ответ', rows: [{ id: 'enabled', type: 'toggle', title: 'Включено', value: true }, { id: 'run', type: 'button', title: 'Запустить', icon: 'bolt.fill' }] }] }])
            await aorus.ui.openPage('main')
            Для больших интерфейсов удобнее native builder:
            const page = aorus.ui.createPage({ id: 'assistant', title: 'Помощник' })
            page.section({ title: 'Ответ' })
              .multiline({ id: 'prompt', title: 'Запрос', value: '' })
              .slider({ id: 'tone', title: 'Тон', min: 0, max: 10, step: 1, value: 5 })
              .button({ id: 'ask', title: 'Спросить AorusAI', icon: 'sparkles' })
              .end()
              .publish()
            await page.open({ style: 'sheet' })
            Стили окна: push, sheet и fullScreen. Типы строк: text, button, toggle, input, multiline, number, select, link, slider и stepper. Для select используется options: [{ value, title }], для link — url, для slider и stepper — min, max и step. update(rowId, value) меняет уже открытый экран. Плагин получает aorus.on('uiAction', event), где есть pageId, rowId и новое value. Клиент строит настоящий UIKit-экран и навигацию; внутренние объекты, UIApplication и селекторы в JavaScript не передаются.

            Интеграции приложения:
            const app = aorus.app.info()
            const account = await aorus.app.currentAccount()
            await aorus.app.openChat('me')
            await aorus.app.openURL('https://example.com')
            await aorus.app.share({ text: 'Готово', url: 'https://example.com' })
            aorus.app.haptic('light')

            App API дает безопасный доступ к состоянию интерфейса, текущему аккаунту, навигации по чатам, браузеру, системному меню отправки и тактильному отклику. Действия проходят через проверяемый нативный broker и отдельные разрешения.

            Аккаунты
            const accounts = await aorus.accounts.list()
            await aorus.accounts.switchTo(accounts[0].id)
            Возвращаются только локальные id, имя, username и признак текущего аккаунта. Ключи авторизации, сессии и токены недоступны. Переключиться можно только на аккаунт, уже добавленный пользователем в приложение.

            Функции и интерфейс
            const all = await aorus.features.list()
            const current = await aorus.features.get('squareAvatars')
            await aorus.features.set('squareAvatars', true)
            const interfaceItems = await aorus.interface.list()
            await aorus.interface.set('compactTabBar', true)
            await aorus.tabs.setVisible('contacts', true)
            await aorus.tabs.setVisible('calls', false)
            await aorus.tabs.setVisible('wall', true)
            await aorus.tabs.setTitlesVisible(true)
            await aorus.tabs.setCompact(true)
            await aorus.avatars.setSquare(true)
            await aorus.wall.setEnabled(true)
            Каталог содержит стабильный id, категорию, тип, текущее значение, допустимый диапазон или варианты и признак перезапуска. В него входят все переключатели центрального менеджера AorusGram: приватность, сообщения, медиа, звонки, вкладки, поиск, подписи и размер панели, аватарки, хранилище и показатели производительности. Сырые UserDefaults и внутренние ключи приложению не выдаются. Изменения применяются через нативные сеттеры и событие appSettingsChanged.

            Соединение
            const state = await aorus.proxy.status()
            await aorus.proxy.setEnabled(true)
            await aorus.proxy.setStableCalls(true)
            await aorus.proxy.refresh()
            Возвращается только очищенное состояние маршрутов. Адреса, UUID, HMAC, ключи REALITY/VLESS и содержимое Keychain никогда не передаются плагину. При изменении пользовательских переключателей приходит connectionChanged.

            Штатные прокси Telegram
            const proxy = await aorus.telegramProxy.status()
            await aorus.telegramProxy.add({ type: 'socks5', host: 'proxy.example', port: 1080, username: 'user', password: 'pass' })
            await aorus.telegramProxy.add({ type: 'mtp', host: 'proxy.example', port: 443, secret: 'ee...' })
            await aorus.telegramProxy.select(0)
            await aorus.telegramProxy.setEnabled(true)
            await aorus.telegramProxy.setUseForCalls(true)
            await aorus.telegramProxy.remove(0)
            status возвращает адрес, порт, тип, активность и наличие учётных данных, но никогда не возвращает сохранённые username, password или MTProto secret.

            Интеграции
            aorus.integrations.settings.register({ id: 'youtube', title: 'YouTube', icon: 'play.rectangle.fill', url: 'https://youtube.com', placement: 'interface' })
            Ярлык содержит ровно одно из полей pageId или url и появляется в основных настройках, но не в списке плагинов. placement: plugins (по умолчанию), privacy, interface, tabs, messages, calls, wall, aorusCode или other. Для url нужна выдача разрешения встроенного браузера при включении плагина. loopback, локальная сеть и служебные домены AorusGram заблокированы.
            aorus.integrations.contextMenu.register({ id: 'reply', title: 'Подготовить ответ', icon: 'message.fill' })
            При выборе приходит aorus.on('contextAction', event) с actionId, source и, когда выбрано одно сообщение, peerId, namespace, messageId и text. События новых сообщений требуют отдельного разрешения. В меню одновременно показываются не более четырёх действий плагинов.

            AorusAI
            const answer = await aorus.ai.ask('Подготовь краткий ответ', {
              history: [{ role: 'user', content: 'Исходный текст' }],
              onEvent(event) {
                if (event.type === 'status') console.log(event.label)
                if (event.type === 'build.phase') console.log(event.label)
              }
            })
            await aorus.ai.openArtifact(answer.artifacts[0].id)
            Для многошагового помощника используйте сессию:
            const chat = aorus.ai.createChat()
            const first = await chat.ask('Предложи ответ', { onEvent(event) { console.log(event.type) } })
            const second = await chat.ask('Сделай его короче')
            chat.messages()
            chat.clear()
            chat.threadId()
            Сессия сама передаёт последние сообщения как историю. Результат содержит text и artifacts с безопасными метаданными файлов: id, filename, mime, size и format. Открыть можно только файл, выданный AorusAI этому плагину в текущем сеансе; загрузка подписывается и проверяется сервером, затем файл открывается в нативном просмотрщике. HMAC, device secret, токены и внутренние маршруты плагину не передаются. Если серверу требуется доступ к Telegram или подтверждение пользователя, запрос нужно продолжить в полном чате AorusAI.

            Настройки плагина
            aorus.settings.addSection({ title: 'Переводчик', items: [
              { key: 'enabled', type: 'toggle', title: 'Включен', default: true },
              { key: 'interval', type: 'slider', title: 'Интервал', min: 10, max: 300, step: 5, default: 60 },
              { key: 'accent', type: 'colorPicker', title: 'Цвет', default: '#30D158' },
              { key: 'reset', type: 'reset', title: 'Сбросить' }
            ] })
            aorus.settings.getPlugin('enabled', true)
            aorus.settings.setPlugin('enabled', false)
            aorus.on('settings.changed', event => console.log(event.key, event.value))
            aorus.on('settings.reset', () => console.log('Reset'))
            Поддерживаются toggle, text, multiline/textarea, number, select, multiSelect, slider, stepper, colorPicker/color, button, reset. button вызывает settings.action с key. Настройки принадлежат конкретному плагину.

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
            Импортированный плагин всегда выключен. Разрешения и значения настроек принадлежат конкретной установке, не экспортируются, а разрешения отзываются при любом изменении исходника. Доступ к AorusAI идет только через ограниченный метод ask. Плагин не имеет API для файловой системы, Keychain, лицензии, VLESS/REALITY credentials, HMAC, сырых настроек или внутренних доменов AorusGram. Защищенные операции повторно проверяют активную лицензию и permission в нативном host.

            Ограничения
            Код: 512 КБ. Хранилище: 1 МБ. HTTP-ответ: 5 МБ. Один вход в JavaScript прерывается через 3 секунды. На плагин разрешено до 64 таймеров и 32 незавершённых запросов к приложению.
            """
        }
        return """
    AorusGram Plugin API v1

    Runtime
    Each plugin runs in a separate JavaScriptCore context. There is no file system, native module loader, eval bridge, Keychain, license, AorusAI internals or tunnel access. Sensitive capabilities require approval and approvals are revoked whenever source code changes.

    Lifecycle
    aorus.on('start', handler)
    aorus.on('stop', handler)
    aorus.on('foreground', handler)
    aorus.on('background', handler)

    Events
    aorus.on(event, handler) returns an unsubscribe function. aorus.once and aorus.off are also available.
    message: { accountId, peerId, senderId, msgId, msgNs, peerKind, text, date }
    messageDeleted: { accountId, peerId, msgId, msgNs }
    messageEdited: { accountId, peerId, msgId, msgNs, originalText, text, date }
    send: { accountId, peerId, text }
    Account and peer identifiers are decimal strings. Message events require their own permission and are scoped to the current account. A send handler may return replacement text, false to consume it, or nothing to leave it unchanged. A Promise from send never delays sending.

    Commands
    aorus.commands.register('name', (args, context) => result, { description, usage })
    aorus.commands.setPrefix('.')
    A synchronous string replaces the typed command. A Promise consumes the command and sends a string result after it resolves. Context contains peerId, accountId, raw and command.

    Messages and chats
    peerId and accountId values are decimal strings so 64-bit identifiers remain exact.
    await aorus.messages.send(peerId, text)
    const message = { peerId, namespace, messageId }
    await aorus.messages.edit(message, 'Updated text')
    await aorus.messages.delete(message, { forEveryone: true })
    await aorus.messages.forward(message, destinationPeerId)
    await aorus.messages.react(message, '👍')
    await aorus.messages.react(message, null)
    await aorus.chats.resolve('username')
    await aorus.chats.get(peerId)
    await aorus.chats.history(peerId, { limit: 50 })
    await aorus.chats.open(peerId)
    await aorus.account.current()
    await aorus.telegram.openLink('tg://resolve?domain=telegram')
    Use 'me' as peerId for Saved Messages. History uses a separate permission and returns sanitized id, namespace, peerId, senderId, text, date, incoming and hasMedia fields. Those peerId, namespace and id values form the reference used by edit/delete/forward/react. The client verifies that the message exists locally before acting, while Telegram enforces edit and deletion rights. One history call is bounded to 100 messages and 128,000 characters. Telegram links use native app navigation. Sending always uses the active account; a mismatched accountId is rejected.

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

    Native pages
    aorus.ui.definePages([{ id: 'main', title: 'Assistant', sections: [{ title: 'Reply', rows: [{ id: 'enabled', type: 'toggle', title: 'Enabled', value: true }, { id: 'run', type: 'button', title: 'Run', icon: 'bolt.fill' }] }] }])
    await aorus.ui.openPage('main')
    For larger interfaces use the native builder:
    const page = aorus.ui.createPage({ id: 'assistant', title: 'Assistant' })
    page.section({ title: 'Reply' })
      .multiline({ id: 'prompt', title: 'Prompt', value: '' })
      .slider({ id: 'tone', title: 'Tone', min: 0, max: 10, step: 1, value: 5 })
      .button({ id: 'ask', title: 'Ask AorusAI', icon: 'sparkles' })
      .end()
      .publish()
    await page.open({ style: 'sheet' })
    Window styles are push, sheet and fullScreen. Row types are text, button, toggle, input, multiline, number, select, link, slider and stepper. select uses options: [{ value, title }]; link uses url; slider and stepper use min, max and step. update(rowId, value) updates a visible screen. The plugin receives aorus.on('uiAction', event) with pageId, rowId and the new value. The client builds the real UIKit screen and navigation; internal objects, UIApplication and selectors never enter JavaScript.

    App integrations:
    const app = aorus.app.info()
    const account = await aorus.app.currentAccount()
    await aorus.app.openChat('me')
    await aorus.app.openURL('https://example.com')
    await aorus.app.share({ text: 'Ready', url: 'https://example.com' })
    aorus.app.haptic('light')

    The App API provides safe access to interface state, the current account, chat navigation, the in-app browser, system share sheet and haptics. Actions use the validated native broker and separate permissions.

    Accounts
    const accounts = await aorus.accounts.list()
    await aorus.accounts.switchTo(accounts[0].id)
    Only local ids, display name, username and current-account state are returned. Authorization keys, sessions and tokens are unavailable. A plugin can switch only to an account already added by the user.

    Features and interface
    const all = await aorus.features.list()
    const current = await aorus.features.get('squareAvatars')
    await aorus.features.set('squareAvatars', true)
    const interfaceItems = await aorus.interface.list()
    await aorus.interface.set('compactTabBar', true)
    await aorus.tabs.setVisible('contacts', true)
    await aorus.tabs.setVisible('calls', false)
    await aorus.tabs.setVisible('wall', true)
    await aorus.tabs.setTitlesVisible(true)
    await aorus.tabs.setCompact(true)
    await aorus.avatars.setSquare(true)
    await aorus.wall.setEnabled(true)
    The catalog returns a stable id, category, type, current value, allowed range or options and restart requirement. It covers every switch in the central AorusGram manager: privacy, messages, media, calls, tabs, search, tab labels and size, avatars, storage and performance metrics. Raw UserDefaults and internal keys are never exposed. Changes use native setters and emit appSettingsChanged.

    Connection
    const state = await aorus.proxy.status()
    await aorus.proxy.setEnabled(true)
    await aorus.proxy.setStableCalls(true)
    await aorus.proxy.refresh()
    Only a sanitized route status is returned. Addresses, UUIDs, HMAC material, REALITY/VLESS credentials and Keychain contents never enter the plugin. Changing user switches emits connectionChanged.

    Telegram proxies
    const proxy = await aorus.telegramProxy.status()
    await aorus.telegramProxy.add({ type: 'socks5', host: 'proxy.example', port: 1080, username: 'user', password: 'pass' })
    await aorus.telegramProxy.add({ type: 'mtp', host: 'proxy.example', port: 443, secret: 'ee...' })
    await aorus.telegramProxy.select(0)
    await aorus.telegramProxy.setEnabled(true)
    await aorus.telegramProxy.setUseForCalls(true)
    await aorus.telegramProxy.remove(0)
    status returns the address, port, type, active state and whether credentials exist, but never returns a saved username, password or MTProto secret.

    Integrations
    aorus.integrations.settings.register({ id: 'youtube', title: 'YouTube', icon: 'play.rectangle.fill', url: 'https://youtube.com', placement: 'interface' })
    A shortcut has exactly one of pageId or url and appears in the main settings, never in the plugin library. placement: plugins (default), privacy, interface, tabs, messages, calls, wall, aorusCode or other. URL shortcuts request browser permission when the plugin is enabled. Loopback, local networks and AorusGram control-plane domains are blocked.
    aorus.integrations.contextMenu.register({ id: 'reply', title: 'Prepare reply', icon: 'message.fill' })
    Selection emits aorus.on('contextAction', event) with actionId and source. For a single selected message it also includes peerId, namespace, messageId and text. New-message events require a separate permission. At most four plugin actions appear at once.

    AorusAI
    const answer = await aorus.ai.ask('Prepare a concise reply', {
      history: [{ role: 'user', content: 'Original text' }],
      onEvent(event) {
        if (event.type === 'status' || event.type === 'build.phase') console.log(event.label)
      }
    })
    await aorus.ai.openArtifact(answer.artifacts[0].id)
    For a multi-turn assistant use a session:
    const chat = aorus.ai.createChat()
    const first = await chat.ask('Suggest a reply', { onEvent(event) { console.log(event.type) } })
    const second = await chat.ask('Make it shorter')
    chat.messages()
    chat.clear()
    chat.threadId()
    The session carries recent messages as history. The result contains text and artifacts with safe file metadata: id, filename, mime, size and format. Only a file returned to this plugin during the current session can be opened; download stays signed and server-authorized, then uses the native preview. HMAC, device secrets, tokens and internal routes never enter the plugin. A request that needs Telegram access or user approval must continue in the full AorusAI chat.

    Plugin settings
    aorus.settings.addSection({ title: 'Translator', items: [
      { key: 'enabled', type: 'toggle', title: 'Enabled', default: true },
      { key: 'interval', type: 'slider', title: 'Interval', min: 10, max: 300, step: 5, default: 60 },
      { key: 'accent', type: 'colorPicker', title: 'Color', default: '#30D158' },
      { key: 'reset', type: 'reset', title: 'Reset' }
    ] })
    aorus.settings.getPlugin('enabled', true)
    aorus.settings.setPlugin('enabled', false)
    aorus.on('settings.changed', event => console.log(event.key, event.value))
    aorus.on('settings.reset', () => console.log('Reset'))
    Available controls: toggle, text, multiline/textarea, number, select, multiSelect, slider, stepper, colorPicker/color, button and reset. A button emits settings.action with its key. Settings belong to the plugin.

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
    Imported plugins always start disabled. Grants and setting values belong to this installation and are never exported; grants are revoked after every source edit. AorusAI is exposed only through the bounded ask method. There is no plugin API for the file system, Keychain, licensing, VLESS/REALITY credentials, raw settings, HMAC or private AorusGram domains. Protected operations re-check both the active license and permission in the native host.

    Limits
    Source: 512 KB. Storage: 1 MB. HTTP response: 5 MB. A JavaScript entry is terminated after 3 seconds. Up to 64 timers and 32 pending host requests are allowed per plugin.
    """
    }
}

/// Renderer for the bounded declarative page model. Plugin code supplies data only; this
/// controller owns every native view and sends sanitized row events back to that plugin.
final class AorusPluginPageController: ViewController, UITableViewDataSource, UITableViewDelegate {
    private let context: AccountContext
    private let pluginId: String
    private var page: AorusPluginUIPage
    private let presentationData: PresentationData
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private var integrationObserver: NSObjectProtocol?

    init(context: AccountContext, pluginId: String, page: AorusPluginUIPage) {
        self.context = context
        self.pluginId = pluginId
        self.page = page
        self.presentationData = context.sharedContext.currentPresentationData.with { $0 }
        super.init(navigationBarPresentationData: NavigationBarPresentationData(presentationData: presentationData, style: .glass))
        title = page.title
        statusBar.statusBarStyle = presentationData.theme.rootController.statusBarStyle.style
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func installModalCloseButton() {
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .close, target: self, action: #selector(closeModal))
    }

    @objc private func closeModal() {
        // A modal page is a controller on Telegram's own stack with a modal presentation,
        // so it leaves the way it arrived.
        if let navigation = navigationController as? NavigationController, navigation.viewControllers.count > 1 {
            _ = navigation.popViewController(animated: true)
        } else {
            dismiss(animated: true)
        }
    }

    deinit {
        if let integrationObserver { NotificationCenter.default.removeObserver(integrationObserver) }
    }

    override func loadDisplayNode() {
        displayNode = ViewControllerTracingNode()
        displayNode.backgroundColor = presentationData.theme.list.blocksBackgroundColor
        tableView.backgroundColor = presentationData.theme.list.blocksBackgroundColor
        tableView.separatorColor = presentationData.theme.list.itemBlocksSeparatorColor
        tableView.dataSource = self
        tableView.delegate = self
        tableView.estimatedRowHeight = 52
        tableView.rowHeight = UITableView.automaticDimension
        displayNode.view.addSubview(tableView)
        integrationObserver = NotificationCenter.default.addObserver(forName: Notification.Name("aorusgram.plugins.integrationsChanged"), object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            guard let updated = AorusPluginRuntimeManager.shared.page(pluginId: self.pluginId, pageId: self.page.id) else {
                // The plugin withdrew the page or stopped. It leaves the same way it came.
                self.closeModal()
                return
            }
            self.page = updated
            self.title = updated.title
            self.tableView.reloadData()
        }
        displayNodeDidLoad()
    }

    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        let top = navigationLayout(layout: layout).navigationFrame.maxY
        transition.updateFrame(view: tableView, frame: CGRect(x: 0, y: top, width: layout.size.width, height: layout.size.height - top))
        tableView.contentInset.bottom = layout.intrinsicInsets.bottom
    }

    func numberOfSections(in tableView: UITableView) -> Int { page.sections.count }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { page.sections[section].rows.count }
    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { page.sections[section].title }
    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? { page.sections[section].footer }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let row = page.sections[indexPath.section].rows[indexPath.row]
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.backgroundColor = presentationData.theme.list.itemBlocksBackgroundColor
        cell.textLabel?.text = row.title
        cell.textLabel?.textColor = row.destructive ? presentationData.theme.list.itemDestructiveColor : presentationData.theme.list.itemPrimaryTextColor
        cell.detailTextLabel?.text = detail(for: row)
        cell.detailTextLabel?.textColor = presentationData.theme.list.itemSecondaryTextColor
        cell.detailTextLabel?.numberOfLines = 0
        if let icon = row.icon {
            cell.imageView?.image = UIImage(systemName: AorusPluginIcon.normalized(icon))
            cell.imageView?.tintColor = presentationData.theme.list.itemAccentColor
        }
        switch row.kind {
        case .toggle:
            let toggle = UISwitch()
            toggle.isOn = row.value?.boolValue ?? false
            toggle.accessibilityIdentifier = "\(indexPath.section):\(indexPath.row)"
            toggle.addTarget(self, action: #selector(toggleChanged(_:)), for: .valueChanged)
            cell.accessoryView = toggle
            cell.selectionStyle = .none
        case .slider:
            let slider = UISlider(frame: CGRect(x: 0, y: 0, width: 150, height: 32))
            slider.minimumValue = Float(row.minimum ?? 0)
            slider.maximumValue = Float(row.maximum ?? 100)
            slider.value = Float(row.value?.doubleValue ?? row.minimum ?? 0)
            slider.isContinuous = false
            slider.accessibilityIdentifier = "\(indexPath.section):\(indexPath.row)"
            slider.addTarget(self, action: #selector(sliderChanged(_:)), for: .valueChanged)
            cell.accessoryView = slider
            cell.selectionStyle = .none
        case .stepper:
            let stepper = UIStepper()
            stepper.minimumValue = row.minimum ?? 0
            stepper.maximumValue = row.maximum ?? 100
            stepper.stepValue = row.step ?? 1
            stepper.value = row.value?.doubleValue ?? row.minimum ?? 0
            stepper.accessibilityIdentifier = "\(indexPath.section):\(indexPath.row)"
            stepper.addTarget(self, action: #selector(stepperChanged(_:)), for: .valueChanged)
            cell.accessoryView = stepper
            cell.selectionStyle = .none
        case .button, .input, .multiline, .number, .select, .link:
            cell.accessoryType = row.kind == .button ? .none : .disclosureIndicator
        case .text:
            cell.selectionStyle = .none
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let row = page.sections[indexPath.section].rows[indexPath.row]
        switch row.kind {
        case .button:
            send(row: row, value: row.value)
        case .link:
            guard let url = row.url else { return }
            AorusPluginRuntimeManager.shared.openURL(pluginId: pluginId, url: url) { [weak self] error in
                guard let self, let error else { return }
                DispatchQueue.main.async { self.show(error) }
            }
        case .select:
            let sheet = UIAlertController(title: row.title, message: row.subtitle, preferredStyle: .actionSheet)
            for option in row.options ?? [] {
                sheet.addAction(UIAlertAction(title: option.title, style: .default) { [weak self] _ in
                    self?.update(rowId: row.id, value: .string(option.value))
                })
            }
            sheet.addAction(UIAlertAction(title: presentationData.strings.Common_Cancel, style: .cancel))
            if let popover = sheet.popoverPresentationController, let cell = tableView.cellForRow(at: indexPath) {
                popover.sourceView = cell; popover.sourceRect = cell.bounds
            }
            present(sheet, animated: true)
        case .multiline:
            let text = row.value?.stringValue ?? ""
            (navigationController as? NavigationController)?.pushViewController(AorusPluginLongTextController(
                presentationData: presentationData,
                title: row.title,
                text: text,
                maxLength: 16_384,
                saved: { [weak self] value in self?.update(rowId: row.id, value: .string(value)) }
            ))
        case .input, .number:
            let alert = UIAlertController(title: row.title, message: row.subtitle, preferredStyle: .alert)
            alert.addTextField {
                if row.kind == .number {
                    $0.text = row.value?.doubleValue.map { String($0) }
                    $0.keyboardType = .decimalPad
                } else {
                    $0.text = row.value?.stringValue
                }
                $0.clearButtonMode = .whileEditing
            }
            alert.addAction(UIAlertAction(title: presentationData.strings.Common_Cancel, style: .cancel))
            alert.addAction(UIAlertAction(title: AorusPluginUIString.save.text, style: .default) { [weak self, weak alert] _ in
                let text = alert?.textFields?.first?.text ?? ""
                if row.kind == .number, let number = Double(text.replacingOccurrences(of: ",", with: ".")) {
                    let bounded = min(row.maximum ?? number, max(row.minimum ?? number, number))
                    self?.update(rowId: row.id, value: .number(bounded))
                } else if row.kind == .input {
                    self?.update(rowId: row.id, value: .string(String(text.prefix(16_384))))
                }
            })
            present(alert, animated: true)
        case .text, .toggle, .slider, .stepper:
            break
        }
    }

    @objc private func toggleChanged(_ sender: UISwitch) {
        guard let indexPath = indexPath(for: sender) else { return }
        let row = page.sections[indexPath.section].rows[indexPath.row]
        update(rowId: row.id, value: .bool(sender.isOn))
    }

    @objc private func sliderChanged(_ sender: UISlider) {
        guard let indexPath = indexPath(for: sender) else { return }
        let row = page.sections[indexPath.section].rows[indexPath.row]
        let step = row.step ?? 1
        let minimum = row.minimum ?? 0
        let snapped = ((Double(sender.value) - minimum) / step).rounded() * step + minimum
        update(rowId: row.id, value: .number(min(row.maximum ?? snapped, max(row.minimum ?? snapped, snapped))))
    }

    @objc private func stepperChanged(_ sender: UIStepper) {
        guard let indexPath = indexPath(for: sender) else { return }
        let row = page.sections[indexPath.section].rows[indexPath.row]
        update(rowId: row.id, value: .number(sender.value))
    }

    private func indexPath(for control: UIControl) -> IndexPath? {
        guard let identifier = control.accessibilityIdentifier else { return nil }
        let parts = identifier.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        let indexPath = IndexPath(row: parts[1], section: parts[0])
        guard page.sections.indices.contains(indexPath.section), page.sections[indexPath.section].rows.indices.contains(indexPath.row) else { return nil }
        return indexPath
    }

    private func update(rowId: String, value: AorusPluginJSONValue) {
        guard let section = page.sections.firstIndex(where: { section in section.rows.contains(where: { $0.id == rowId }) }),
              let rowIndex = page.sections[section].rows.firstIndex(where: { $0.id == rowId }) else { return }
        let indexPath = IndexPath(row: rowIndex, section: section)
        page.sections[indexPath.section].rows[indexPath.row].value = value
        let row = page.sections[indexPath.section].rows[indexPath.row]
        tableView.reloadRows(at: [indexPath], with: .none)
        send(row: row, value: value)
    }

    private func send(row: AorusPluginUIPage.Row, value: AorusPluginJSONValue?) {
        AorusPluginRuntimeManager.shared.dispatchUIAction(pluginId: pluginId, pageId: page.id, rowId: row.id, value: value)
    }

    private func detail(for row: AorusPluginUIPage.Row) -> String? {
        if row.kind == .select, let value = row.value?.stringValue,
           let option = row.options?.first(where: { $0.value == value }) { return option.title }
        if row.kind == .input, let value = row.value?.stringValue, !value.isEmpty { return value }
        if row.kind == .multiline, let value = row.value?.stringValue, !value.isEmpty {
            return value.replacingOccurrences(of: "\n", with: " ")
        }
        if [.number, .slider, .stepper].contains(row.kind), let value = row.value?.doubleValue {
            return value.rounded() == value ? String(Int(value)) : String(value)
        }
        return row.subtitle
    }

    private func show(_ error: Error) {
        let alert = UIAlertController(title: page.title, message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

/// What a plugin is doing right now, read from the runtime rather than from the manifest.
/// The manifest says what was asked for; this says what happened.
private struct AorusPluginStatus {
    var badge: String
    var detail: String
    var color: UIColor
    var isFailure: Bool

    init(pluginId: String, record: AorusPluginRecord) {
        let sandbox = AorusPluginRuntimeManager.shared.sandbox(id: pluginId)
        let granted = AorusPluginStore.shared.permissionState(for: pluginId)
        let requested = AorusPluginPermission.requestedBySource(record.source)
        let digestMatches = granted.sourceDigest == AorusPluginStore.sourceDigest(record.source)
        if let error = sandbox?.lastError, !error.isEmpty {
            badge = AorusPluginUIString.failed.text
            detail = error
            color = .systemRed
            isFailure = true
        } else if sandbox?.isHung == true {
            badge = AorusPluginUIString.failed.text
            detail = AorusPluginUIString.failed.text
            color = .systemRed
            isFailure = true
        } else if sandbox?.isRunning == true {
            badge = AorusPluginUIString.running.text
            detail = AorusPluginUIString.running.text
            color = .systemGreen
            isFailure = false
        } else if !record.manifest.isEnabled {
            badge = AorusPluginUIString.stopped.text
            detail = AorusPluginUIString.stopped.text
            color = .systemGray
            isFailure = false
        } else if !digestMatches || !requested.isSubset(of: granted.granted) {
            badge = AorusPluginUIString.stopped.text
            detail = AorusPluginUIString.reviewPermissions.text
            color = .systemOrange
            isFailure = false
        } else if !AorusPluginSandbox.watchdogAvailable {
            badge = AorusPluginUIString.failed.text
            detail = AorusPluginUIString.isolation.text + ": " + AorusPluginUIString.unavailable.text
            color = .systemRed
            isFailure = true
        } else {
            badge = AorusPluginUIString.stopped.text
            detail = AorusPluginUIString.stopped.text
            color = .systemGray
            isFailure = false
        }
    }
}

/// A small pill. The list and the card both need one, and a label with a background is not
/// a badge until it has the padding and the corner to read as one.
private final class AorusPluginBadgeView: UIView {
    private let label = UILabel()

    init(text: String, color: UIColor) {
        super.init(frame: .zero)
        label.text = text.uppercased()
        label.font = .systemFont(ofSize: 11, weight: .bold)
        label.textColor = color
        addSubview(label)
        backgroundColor = color.withAlphaComponent(0.16)
        layer.cornerRadius = 9
        layer.cornerCurve = .continuous
        let size = label.sizeThatFits(CGSize(width: 200, height: 40))
        label.frame = CGRect(x: 9, y: 3, width: min(160, size.width), height: 18)
        frame = CGRect(x: 0, y: 0, width: label.frame.width + 18, height: 24)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// Everything needed to answer "why did nothing happen", on one screen: whether the plugin
/// is running, what it registered, what it was granted, and whether the system can isolate
/// its execution at all. Without this the only way to tell a stopped plugin from a working
/// one that was never granted anything is to read the source and guess.
private final class AorusPluginDiagnosticsController: ViewController, UITableViewDataSource, UITableViewDelegate {
    private let record: AorusPluginRecord
    private let presentationData: PresentationData
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private var rows: [(String, String, Bool)] = []

    init(context: AccountContext, record: AorusPluginRecord) {
        self.record = record
        self.presentationData = context.sharedContext.currentPresentationData.with { $0 }
        super.init(navigationBarPresentationData: NavigationBarPresentationData(presentationData: presentationData, style: .glass))
        title = AorusPluginUIString.diagnostics.text
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadDisplayNode() {
        displayNode = ViewControllerTracingNode()
        displayNode.backgroundColor = presentationData.theme.list.blocksBackgroundColor
        tableView.backgroundColor = presentationData.theme.list.blocksBackgroundColor
        tableView.dataSource = self
        tableView.delegate = self
        tableView.estimatedRowHeight = 52
        tableView.rowHeight = UITableView.automaticDimension
        displayNode.view.addSubview(tableView)
        rebuild()
        displayNodeDidLoad()
    }

    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        let top = navigationLayout(layout: layout).navigationFrame.maxY
        transition.updateFrame(view: tableView, frame: CGRect(x: 0, y: top, width: layout.size.width, height: layout.size.height - top))
        tableView.contentInset.bottom = layout.intrinsicInsets.bottom
    }

    private func rebuild() {
        let pluginId = record.manifest.id
        let sandbox = AorusPluginRuntimeManager.shared.sandbox(id: pluginId)
        let state = AorusPluginStatus(pluginId: pluginId, record: record)
        let granted = AorusPluginStore.shared.permissionState(for: pluginId).granted
        let requested = AorusPluginPermission.requestedBySource(record.source)
        let registration = sandbox?.registration() ?? AorusPluginSandbox.Registration()

        var result: [(String, String, Bool)] = []
        result.append((AorusPluginUIString.status.text, state.detail, state.isFailure))
        result.append((
            AorusPluginUIString.isolation.text,
            AorusPluginSandbox.watchdogAvailable ? AorusPluginUIString.available.text : AorusPluginUIString.unavailable.text,
            !AorusPluginSandbox.watchdogAvailable
        ))
        result.append((
            AorusPluginUIString.outgoingHook.text,
            sandbox?.hasOutgoingHooks == true ? AorusPluginUIString.active.text : AorusPluginUIString.inactive.text,
            false
        ))
        let commands = registration.commands.map { registration.prefix + $0 }
        result.append((
            AorusPluginUIString.commands.text,
            commands.isEmpty ? AorusPluginUIString.noCommands.text : commands.joined(separator: "  "),
            commands.isEmpty
        ))
        result.append((
            AorusPluginUIString.events.text,
            registration.events.isEmpty ? "-" : registration.events.joined(separator: "  "),
            false
        ))
        let grantedNames = granted.sorted { $0.rawValue < $1.rawValue }.map { permissionTitle($0) }
        result.append((
            AorusPluginUIString.granted.text,
            grantedNames.isEmpty ? AorusPluginUIString.noPermissions.text : grantedNames.joined(separator: ", "),
            !requested.isSubset(of: granted)
        ))
        // The running plugin's own log. Until now it existed only behind the editor's Run
        // button, so a plugin that failed while actually installed had nowhere to say so.
        let log = (sandbox?.recentLog ?? []).suffix(12)
        if !log.isEmpty {
            result.append((
                AorusPluginUIString.console.text,
                log.map { "[\($0.level.rawValue)] \($0.text)" }.joined(separator: "\n"),
                log.contains(where: { $0.level == .error })
            ))
        }
        rows = result
        tableView.reloadData()
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { rows.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let row = rows[indexPath.row]
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.backgroundColor = presentationData.theme.list.itemBlocksBackgroundColor
        cell.selectionStyle = .none
        cell.textLabel?.text = row.0
        cell.textLabel?.textColor = presentationData.theme.list.itemPrimaryTextColor
        cell.detailTextLabel?.text = row.1
        cell.detailTextLabel?.numberOfLines = 0
        cell.detailTextLabel?.textColor = row.2
            ? presentationData.theme.list.itemDestructiveColor
            : presentationData.theme.list.itemSecondaryTextColor
        return cell
    }
}

/// The running plugin's console.
///
/// The editor has a console too, but that one belongs to the throwaway sandbox behind the
/// Run button — it shows nothing about the plugin that is actually installed and handling
/// taps. This one reads the live sandbox: everything the plugin logged, everything the app
/// logged about it, and it keeps updating while the screen is open.
private final class AorusPluginConsoleController: ViewController {
    private let record: AorusPluginRecord
    private let presentationData: PresentationData
    private let textView = UITextView()
    private let emptyLabel = UILabel()
    private var timer: Timer?
    private var shownCount = -1
    private var atBottom = true

    init(context: AccountContext, record: AorusPluginRecord) {
        self.record = record
        self.presentationData = context.sharedContext.currentPresentationData.with { $0 }
        super.init(navigationBarPresentationData: NavigationBarPresentationData(presentationData: presentationData, style: .glass))
        title = AorusPluginUIString.console.text
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "trash"),
            style: .plain,
            target: self,
            action: #selector(clearLog)
        )
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { timer?.invalidate() }

    override func loadDisplayNode() {
        displayNode = ViewControllerTracingNode()
        let dark = presentationData.theme.overallDarkAppearance
        displayNode.backgroundColor = dark ? UIColor(red: 0.055, green: 0.059, blue: 0.071, alpha: 1.0) : UIColor(red: 0.96, green: 0.97, blue: 0.98, alpha: 1.0)
        textView.backgroundColor = .clear
        textView.isEditable = false
        textView.alwaysBounceVertical = true
        textView.font = .monospacedSystemFont(ofSize: 12.0, weight: .regular)
        textView.textContainerInset = UIEdgeInsets(top: 14.0, left: 14.0, bottom: 24.0, right: 14.0)
        textView.delegate = self
        emptyLabel.text = AorusPluginUIString.consoleEmpty.text
        emptyLabel.textAlignment = .center
        emptyLabel.numberOfLines = 0
        emptyLabel.font = .systemFont(ofSize: 15.0)
        emptyLabel.textColor = presentationData.theme.list.itemSecondaryTextColor
        displayNode.view.addSubview(textView)
        displayNode.view.addSubview(emptyLabel)
        refresh()
        // A log is only useful while it is still happening. Half a second is below the rate
        // at which anyone reads and far above the cost of reading an array under a lock.
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        displayNodeDidLoad()
    }

    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        let top = navigationLayout(layout: layout).navigationFrame.maxY
        let frame = CGRect(x: 0.0, y: top, width: layout.size.width, height: max(0.0, layout.size.height - top))
        transition.updateFrame(view: textView, frame: frame)
        emptyLabel.frame = frame.insetBy(dx: 32.0, dy: 0.0)
        textView.contentInset.bottom = layout.intrinsicInsets.bottom
    }

    private func refresh() {
        let entries = AorusPluginRuntimeManager.shared.sandbox(id: record.manifest.id)?.recentLog ?? []
        guard entries.count != shownCount else { return }
        shownCount = entries.count
        emptyLabel.isHidden = !entries.isEmpty
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let text = NSMutableAttributedString()
        for entry in entries {
            let stamp = NSAttributedString(
                string: formatter.string(from: entry.date) + "  ",
                attributes: [
                    .font: UIFont.monospacedSystemFont(ofSize: 11.0, weight: .regular),
                    .foregroundColor: presentationData.theme.list.itemSecondaryTextColor
                ]
            )
            let body = NSAttributedString(
                string: entry.text + "\n",
                attributes: [
                    .font: UIFont.monospacedSystemFont(ofSize: 12.0, weight: entry.level == .error ? .semibold : .regular),
                    .foregroundColor: AorusPluginConsoleController.color(for: entry.level, theme: presentationData.theme)
                ]
            )
            text.append(stamp)
            text.append(body)
        }
        textView.attributedText = text
        if atBottom, text.length > 0 {
            textView.scrollRangeToVisible(NSRange(location: text.length - 1, length: 1))
        }
    }

    private static func color(for level: AorusPluginLogEntry.Level, theme: PresentationTheme) -> UIColor {
        switch level {
        case .error: return .systemRed
        case .warn: return .systemOrange
        case .debug: return theme.list.itemSecondaryTextColor
        case .info: return theme.overallDarkAppearance ? UIColor(red: 0.55, green: 0.95, blue: 0.68, alpha: 1.0) : theme.list.itemPrimaryTextColor
        }
    }

    @objc private func clearLog() {
        AorusPluginRuntimeManager.shared.sandbox(id: record.manifest.id)?.clearLog()
        shownCount = -1
        refresh()
    }
}

extension AorusPluginConsoleController: UITextViewDelegate {
    /// Stop following the tail once someone scrolls up to read something.
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let distance = scrollView.contentSize.height - scrollView.contentOffset.y - scrollView.bounds.height
        atBottom = distance < 40.0
    }
}

private final class AorusPluginCell: UITableViewCell {
    var onToggle: ((Bool) -> Void)?
    private let toggle = UISwitch()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: .subtitle, reuseIdentifier: reuseIdentifier)
        accessoryView = toggle
        toggle.addTarget(self, action: #selector(changed), for: .valueChanged)
        selectionStyle = .default
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(manifest: AorusPluginManifest, record: AorusPluginRecord?, theme: PresentationTheme) {
        textLabel?.text = manifest.name
        detailTextLabel?.text = manifest.summary.isEmpty ? manifest.version : manifest.summary
        textLabel?.textColor = theme.list.itemPrimaryTextColor
        detailTextLabel?.textColor = theme.list.itemSecondaryTextColor
        imageView?.image = UIImage(systemName: AorusPluginIcon.normalized(manifest.icon))
        imageView?.tintColor = pluginColor(manifest.accent)
        toggle.isOn = manifest.isEnabled
    }

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
    case .messageHistory: return aorusL("История сообщений", "Read message history")
    case .outgoingMessages: return aorusL("Обработка исходящих сообщений", "Process outgoing messages")
    case .customUI: return aorusL("Собственные экраны", "Custom screens")
    case .settingsIntegration: return AorusPluginUIString.settings.text
    case .contextMenu: return aorusL("Контекстное меню", "Context menu")
    case .inAppBrowser: return aorusL("Встроенный браузер", "In-app browser")
    case .artificialIntelligence: return "AorusAI"
    case .appCustomization: return aorusL("Настройка приложения", "Customize app")
    case .connectionControl: return aorusL("Управление соединением", "Connection control")
    case .accountSwitching: return aorusL("Аккаунты", "Accounts")
    case .telegramProxy: return aorusL("Прокси Telegram", "Telegram proxies")
    case .manageMessages: return aorusL("Управление сообщениями", "Manage messages")
    case .composer: return aorusL("Поле ввода открытого чата", "Open chat composer")
    case .pluginMessaging: return aorusL("Обмен с другими плагинами", "Talk to other plugins")
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
    case .messageHistory:
        return marker + aorusL("Разрешает читать до 100 последних сообщений выбранного чата.", "Allows reading up to 100 recent messages from a selected chat.")
    case .outgoingMessages:
        return marker + aorusL("Разрешает изменять или отменять отправляемый текст.", "Allows changing or consuming outgoing text.")
    case .customUI:
        return marker + aorusL("Разрешает создавать нативные страницы из проверенных элементов.", "Allows native pages made from validated controls.")
    case .settingsIntegration:
        return marker + aorusL("Разрешает добавлять ярлыки в раздел плагинов.", "Allows shortcuts in the Plugins section.")
    case .contextMenu:
        return marker + aorusL("Разрешает добавлять действия в меню сообщения без доступа к его содержимому.", "Allows message-menu actions without implicit access to message contents.")
    case .inAppBrowser:
        return marker + aorusL("Разрешает открывать публичные сайты во встроенном браузере.", "Allows public websites in the in-app browser.")
    case .artificialIntelligence:
        return marker + aorusL("Разрешает отправлять запросы AorusAI через защищенный клиентский шлюз.", "Allows AorusAI requests through the protected client gateway.")
    case .appCustomization:
        return marker + aorusL("Разрешает изменять функции и оформление AorusGram из проверенного списка.", "Allows changing AorusGram features and appearance from a verified catalog.")
    case .connectionControl:
        return marker + aorusL("Разрешает читать состояние маршрута, менять пользовательские переключатели и запускать перепроверку без доступа к ключам серверов.", "Allows reading route status, changing user switches and refreshing the route without access to server credentials.")
    case .accountSwitching:
        return marker + aorusL("Разрешает видеть локальные аккаунты и переключать активный аккаунт без доступа к ключам авторизации.", "Allows listing local accounts and switching the active account without access to authorization keys.")
    case .telegramProxy:
        return marker + aorusL("Разрешает управлять штатными прокси Telegram. Сохранённые пароли и секреты плагину не раскрываются.", "Allows managing Telegram proxies. Saved passwords and secrets are never exposed to the plugin.")
    case .manageMessages:
        return marker + aorusL("Разрешает редактировать, удалять, пересылать сообщения и менять реакции от имени текущего аккаунта.", "Allows editing, deleting and forwarding messages and changing reactions as the current account.")
    case .pluginMessaging:
        return marker + aorusL("Разрешает обмениваться сообщениями с другими установленными плагинами. Каждое сообщение несет идентификатор отправителя, и плагины без этого разрешения ничего не получают и ничего не отправляют.", "Allows exchanging messages with other installed plugins. Every message carries the sender's identifier, and plugins without this permission neither send nor receive anything.")
    case .composer:
        return marker + aorusL("Разрешает менять текст в поле ввода открытого чата, видеть, как он меняется при наборе, показывать статус печати и прокручивать историю. Отправку сообщений это разрешение не дает.", "Allows changing the text in the open chat composer, seeing it change as it is typed, showing the typing status and scrolling the history. It does not allow sending messages.")
    }
}

/// The six digits a colour is stored as. The picker hands back a UIColor; the manifest
/// keeps "RRGGBB", and every tile is drawn from that.
private func aorusHexString(_ color: UIColor) -> String {
    var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
    guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
        return AorusPluginAccent.fallback
    }
    let channel: (CGFloat) -> Int = { Int((min(1.0, max(0.0, $0)) * 255.0).rounded()) }
    return String(format: "%02X%02X%02X", channel(red), channel(green), channel(blue))
}

@available(iOS 14.0, *)
private final class AorusPluginColorPickerDelegate: NSObject, UIColorPickerViewControllerDelegate {
    private let changed: (UIColor) -> Void

    init(changed: @escaping (UIColor) -> Void) {
        self.changed = changed
    }

    func colorPickerViewControllerDidSelectColor(_ viewController: UIColorPickerViewController) {
        changed(viewController.selectedColor)
    }

    func colorPickerViewControllerDidFinish(_ viewController: UIColorPickerViewController) {
        changed(viewController.selectedColor)
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
