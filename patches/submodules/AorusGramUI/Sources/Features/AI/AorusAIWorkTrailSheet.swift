import Foundation
import UIKit
import TelegramPresentationData
import AorusGram

/// The agent's account of what it did, as a half-screen sheet.
///
/// The chat itself shows one line — the phase being worked on, or what the turn cost —
/// and this is what opens behind that line. It is the same kind of sheet the AI companion
/// menu uses: a page sheet at the medium detent with a grabber, so the two read as one
/// family rather than two inventions.
///
/// Drawn as a list rather than a single branch: a phase is a task with a state, and a
/// state wants a glyph in a column of its own — a checkmark once it is behind us, a
/// turning ring while it is the one running. The files a phase touched are a branch, and
/// they are drawn as one, hanging off the phase that owns them.
public func aorusAIPresentWorkTrail(phases: [AorusAIWorkPhase],
                                    isRunning: Bool,
                                    finishedAt: Date?,
                                    theme: PresentationTheme,
                                    from presenter: UIViewController) {
    guard !phases.isEmpty else { return }
    let controller = AorusAIWorkTrailController(
        phases: phases,
        isRunning: isRunning,
        finishedAt: finishedAt,
        theme: theme
    )
    controller.modalPresentationStyle = .pageSheet
    if #available(iOS 15.0, *) {
        controller.sheetPresentationController?.detents = [.medium(), .large()]
        controller.sheetPresentationController?.selectedDetentIdentifier = .medium
        controller.sheetPresentationController?.prefersGrabberVisible = true
        controller.sheetPresentationController?.prefersScrollingExpandsWhenScrolledToEdge = true
    }
    controller.preferredContentSize = CGSize(width: 420.0, height: 560.0)
    presenter.present(controller, animated: true)
}

// MARK: - Controller

private final class AorusAIWorkTrailController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    /// One line of the list. Phases are always present; a phase's files appear under it
    /// only while it is open.
    private enum Row {
        case phase(Int)
        case file(phase: Int, file: Int)
    }

    private let phases: [AorusAIWorkPhase]
    private let isRunning: Bool
    private let finishedAt: Date?
    private let palette: AorusAIPalette

    private let titleLabel = UILabel()
    private let tableView = UITableView(frame: .zero, style: .plain)
    /// Which phases the reader has opened. A phase with no renderable file never enters
    /// this set, because there is nothing to show and a row that opens onto nothing is
    /// worse than one that does not react at all.
    private var openPhases: Set<Int> = []
    private var rows: [Row] = []
    private var ticker: Timer?

    init(phases: [AorusAIWorkPhase], isRunning: Bool, finishedAt: Date?, theme: PresentationTheme) {
        self.phases = phases
        self.isRunning = isRunning
        self.finishedAt = finishedAt
        self.palette = AorusAIPalette.resolve(theme)
        super.init(nibName: nil, bundle: nil)
        rebuildRows()
    }

    required init?(coder: NSCoder) { preconditionFailure("AorusAIWorkTrailController is not built from a coder") }

    deinit {
        ticker?.invalidate()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = palette.background

        titleLabel.font = .systemFont(ofSize: 20.0, weight: .bold)
        titleLabel.textColor = palette.label
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 1
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(titleLabel)

        tableView.backgroundColor = .clear
        tableView.separatorStyle = .none
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 34.0
        tableView.contentInset = UIEdgeInsets(top: 4.0, left: 0.0, bottom: 20.0, right: 0.0)
        tableView.register(PhaseCell.self, forCellReuseIdentifier: PhaseCell.reuseIdentifier)
        tableView.register(FileCell.self, forCellReuseIdentifier: FileCell.reuseIdentifier)
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 18.0),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20.0),
            titleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20.0),
            tableView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 14.0),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        updateTitle()
        // A running turn's cost keeps climbing while the sheet is open, so the heading is
        // re-read every second rather than frozen at the moment it was presented.
        if isRunning {
            let ticker = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.updateTitle()
            }
            RunLoop.main.add(ticker, forMode: .common)
            self.ticker = ticker
        }
    }

    private func updateTitle() {
        let started = phases.first?.startedAt
        let end = isRunning ? Date() : (finishedAt ?? Date())
        let duration = started.map { max(0.0, end.timeIntervalSince($0)) }
        titleLabel.text = isRunning
            ? AorusAIWorkTrailView.runningText(duration: duration)
            : AorusAIWorkTrailView.summaryText(duration: duration)
    }

    private func renderableFiles(_ index: Int) -> [AorusAIFileChange] {
        guard phases.indices.contains(index) else { return [] }
        return phases[index].files.filter { $0.isRenderable }
    }

    private func rebuildRows() {
        var rows: [Row] = []
        for index in phases.indices {
            rows.append(.phase(index))
            guard openPhases.contains(index) else { continue }
            for file in renderableFiles(index).indices {
                rows.append(.file(phase: index, file: file))
            }
        }
        self.rows = rows
    }

    /// The phase that is being worked on: the last one, and only while the turn runs.
    private func isActive(_ index: Int) -> Bool {
        return isRunning && index == phases.count - 1
    }

    // MARK: UITableViewDataSource

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return rows.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch rows[indexPath.row] {
        case let .phase(index):
            guard let cell = tableView.dequeueReusableCell(withIdentifier: PhaseCell.reuseIdentifier, for: indexPath) as? PhaseCell else {
                return UITableViewCell()
            }
            cell.configure(
                text: phases[index].label,
                palette: palette,
                isActive: isActive(index),
                hasFiles: !renderableFiles(index).isEmpty,
                isOpen: openPhases.contains(index),
                // The rail joins this row to the next, so the last row has none.
                continues: index < phases.count - 1 || openPhases.contains(index)
            )
            return cell
        case let .file(phase, file):
            guard let cell = tableView.dequeueReusableCell(withIdentifier: FileCell.reuseIdentifier, for: indexPath) as? FileCell else {
                return UITableViewCell()
            }
            let files = renderableFiles(phase)
            guard files.indices.contains(file) else { return cell }
            cell.configure(
                file: files[file],
                palette: palette,
                isLast: file == files.count - 1
            )
            return cell
        }
    }

    // MARK: UITableViewDelegate

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        guard case let .phase(index) = rows[indexPath.row] else { return }
        // A phase that touched nothing does not react at all. There is no empty state to
        // show and opening onto one would be a worse answer than staying shut.
        guard !renderableFiles(index).isEmpty else { return }
        if openPhases.contains(index) {
            openPhases.remove(index)
        } else {
            openPhases.insert(index)
        }
        let previous = rows
        rebuildRows()
        applyRowChange(from: previous, to: rows, phase: index)
    }

    /// Insert or remove exactly the file rows that changed, so the rest of the list stays
    /// put and the chevron turns in the same animation.
    private func applyRowChange(from previous: [Row], to next: [Row], phase: Int) {
        guard let anchor = next.firstIndex(where: { row in
            if case let .phase(index) = row { return index == phase }
            return false
        }) else {
            tableView.reloadData()
            return
        }
        let opened = next.count > previous.count
        let delta = abs(next.count - previous.count)
        guard delta > 0 else { return }
        let paths = (1...delta).map { IndexPath(row: anchor + $0, section: 0) }
        tableView.performBatchUpdates({
            if opened {
                tableView.insertRows(at: paths, with: .fade)
            } else {
                tableView.deleteRows(at: paths, with: .fade)
            }
        }, completion: nil)
        if let cell = tableView.cellForRow(at: IndexPath(row: anchor, section: 0)) as? PhaseCell {
            cell.setOpen(openPhases.contains(phase), animated: true)
        }
    }
}

// MARK: - Phase row

/// One task: its state on the left, its name beside it, and the rail that joins it to the
/// next one.
private final class PhaseCell: UITableViewCell {
    static let reuseIdentifier = "AorusAIWorkTrailPhaseCell"
    private let glyph = UIImageView()
    private let spinner = AorusAIWorkTrailSpinner()
    private let rail = UIView()
    private let label = UILabel()
    private let chevron = UIImageView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none

        glyph.contentMode = .scaleAspectFit
        glyph.image = UIImage(
            systemName: "checkmark",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 11.0, weight: .semibold)
        )
        glyph.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(glyph)

        spinner.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(spinner)

        rail.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(rail)

        label.font = .systemFont(ofSize: 15.0)
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(label)

        chevron.contentMode = .scaleAspectFit
        chevron.image = UIImage(
            systemName: "chevron.right",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 10.0, weight: .semibold)
        )
        chevron.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(chevron)

        NSLayoutConstraint.activate([
            glyph.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20.0),
            glyph.widthAnchor.constraint(equalToConstant: 16.0),
            glyph.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 11.0),
            glyph.heightAnchor.constraint(equalToConstant: 16.0),
            spinner.centerXAnchor.constraint(equalTo: glyph.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: glyph.centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 15.0),
            spinner.heightAnchor.constraint(equalToConstant: 15.0),
            // The rail hangs from under the glyph to the bottom of the row, so
            // consecutive rows draw one continuous line through the column.
            rail.centerXAnchor.constraint(equalTo: glyph.centerXAnchor),
            rail.widthAnchor.constraint(equalToConstant: 1.0),
            rail.topAnchor.constraint(equalTo: glyph.bottomAnchor, constant: 3.0),
            rail.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 46.0),
            label.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8.0),
            label.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8.0),
            chevron.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8.0),
            chevron.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20.0),
            chevron.centerYAnchor.constraint(equalTo: glyph.centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 12.0),
            // The glyph needs 11 + 16 points and the rail starts 3 below it, so a
            // shorter row than this would make the rail's own height negative.
            contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 38.0)
        ])
    }

    required init?(coder: NSCoder) { preconditionFailure("PhaseCell is not built from a coder") }

    func configure(text: String,
                   palette: AorusAIPalette,
                   isActive: Bool,
                   hasFiles: Bool,
                   isOpen: Bool,
                   continues: Bool) {
        label.text = text
        // The task being worked on reads brighter than the ones behind it — that is the
        // whole difference, and it is carried by weight and ink rather than by colour.
        label.textColor = isActive ? palette.label : palette.secondary
        label.font = .systemFont(ofSize: 15.0, weight: isActive ? .medium : .regular)
        glyph.tintColor = palette.secondary
        glyph.isHidden = isActive
        spinner.isHidden = !isActive
        spinner.color = palette.label
        spinner.setSpinning(isActive)
        rail.backgroundColor = palette.separator
        rail.isHidden = !continues
        chevron.tintColor = palette.tertiary
        chevron.isHidden = !hasFiles
        setOpen(isOpen, animated: false)
    }

    /// A quarter turn rather than a second glyph, so the two states are one object.
    func setOpen(_ open: Bool, animated: Bool) {
        let transform = open ? CGAffineTransform(rotationAngle: .pi / 2.0) : .identity
        guard animated else {
            chevron.transform = transform
            return
        }
        UIView.animate(withDuration: 0.28, delay: 0.0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0.0, options: [.beginFromCurrentState]) {
            self.chevron.transform = transform
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        spinner.setSpinning(false)
        chevron.transform = .identity
    }
}

// MARK: - File row

/// One file the phase above touched, hanging off it as a branch.
private final class FileCell: UITableViewCell {
    static let reuseIdentifier = "AorusAIWorkTrailFileCell"

    private let label = UILabel()
    private var branch: AorusAIWorkTrailView.BranchRow?
    private let holder = UIView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none

        holder.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(holder)
        NSLayoutConstraint.activate([
            // 25 + BranchRow.origin puts the trunk at 28, which is the centre of the phase
            // glyph's column (20 leading + half of a 16-point glyph) — so a file hangs off
            // the rail its phase drew rather than off a line of its own.
            holder.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 25.0),
            holder.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20.0),
            holder.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 1.0),
            holder.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -1.0)
        ])

        label.font = .systemFont(ofSize: 12.0)
        label.numberOfLines = 0
    }

    required init?(coder: NSCoder) { preconditionFailure("FileCell is not built from a coder") }

    func configure(file: AorusAIFileChange, palette: AorusAIPalette, isLast: Bool) {
        label.attributedText = AorusAIWorkTrailView.attributedRow(file, palette: palette)
        // The branch is rebuilt rather than reconfigured: its shape is fixed at init by
        // the depth and the rules above it, and a reused cell can be any of them.
        branch?.removeFromSuperview()
        let branch = AorusAIWorkTrailView.BranchRow(
            content: label,
            depth: 0,
            isLastAtDepth: isLast,
            ancestorContinues: [],
            colour: palette.separator
        )
        branch.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(branch)
        NSLayoutConstraint.activate([
            branch.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
            branch.trailingAnchor.constraint(equalTo: holder.trailingAnchor),
            branch.topAnchor.constraint(equalTo: holder.topAnchor),
            branch.bottomAnchor.constraint(equalTo: holder.bottomAnchor)
        ])
        self.branch = branch
    }
}

// MARK: - Spinner

/// The ring that turns while a task is being worked on.
///
/// A three-quarter arc rather than `UIActivityIndicatorView`: the system spinner is a
/// spoked wheel in the system's own grey, and this has to be one hairline ring in the
/// page's ink, the same weight as the checkmark it stands in for.
private final class AorusAIWorkTrailSpinner: UIView {
    private let ring = CAShapeLayer()
    private var spinning = false
    private var foregroundObserver: NSObjectProtocol?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        ring.fillColor = UIColor.clear.cgColor
        ring.lineWidth = 1.5
        ring.lineCap = .round
        layer.addSublayer(ring)
        // Same reason the phase line re-arms itself: iOS strips every animation off the
        // layer tree when the app is backgrounded and does not put it back.
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.applySpin(force: true)
        }
    }

    required init?(coder: NSCoder) { preconditionFailure("AorusAIWorkTrailSpinner is not built from a coder") }

    deinit {
        if let foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
        }
    }

    /// Its own property rather than an override of `tintColor`: that one is inherited
    /// down the view tree and set by UIKit itself, so overriding it here would be two
    /// things writing one value.
    var color: UIColor = .white {
        didSet {
            ring.strokeColor = color.cgColor
        }
    }

    func setSpinning(_ value: Bool) {
        guard spinning != value else { return }
        spinning = value
        applySpin(force: false)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        applySpin(force: false)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inset = ring.lineWidth / 2.0
        let rect = bounds.insetBy(dx: inset, dy: inset)
        guard rect.width > 0.0, rect.height > 0.0 else { return }
        ring.frame = bounds
        ring.path = UIBezierPath(
            arcCenter: CGPoint(x: bounds.midX, y: bounds.midY),
            radius: min(rect.width, rect.height) / 2.0,
            startAngle: -.pi / 2.0,
            endAngle: .pi,
            clockwise: true
        ).cgPath
        applySpin(force: false)
    }

    private func applySpin(force: Bool) {
        guard spinning, window != nil, bounds.width > 1.0 else {
            ring.removeAnimation(forKey: "aorusTrailSpin")
            return
        }
        // Left alone unless it is genuinely absent, so a layout pass does not jump the
        // ring back to its starting angle.
        if !force, ring.animation(forKey: "aorusTrailSpin") != nil {
            return
        }
        ring.removeAnimation(forKey: "aorusTrailSpin")
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0.0
        spin.toValue = 2.0 * Double.pi
        spin.duration = 0.9
        spin.repeatCount = .infinity
        // Linear: a ring that eases is a ring that looks like it is struggling.
        spin.timingFunction = CAMediaTimingFunction(name: .linear)
        ring.add(spin, forKey: "aorusTrailSpin")
    }
}
