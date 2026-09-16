import SwiftUI

// Standalone screen listing deleted messages for a specific chat (or all chats).
// Open from the chat context menu: "Удалённые сообщения".
struct DeletedMessagesView: View {
    let peerId: Int64
    /// `account.postbox.mediaBox.basePath` of the account being shown. The cache keeps one
    /// account's rows out of another's and needs to be told which one is asking.
    let accountStoragePath: String
    let peerName: String

    @State private var messages: [DeletedMessage] = []
    @State private var isLoading = true
    @State private var searchText = ""

    private var filtered: [DeletedMessage] {
        guard !searchText.isEmpty else { return messages }
        let q = searchText.lowercased()
        return messages.filter {
            $0.text.lowercased().contains(q) ||
            $0.senderName.lowercased().contains(q)
        }
    }

    var body: some View {
        ZStack {
            AorusAnimatedBackground()

            if isLoading {
                ProgressView("Загрузка...")
                    .foregroundColor(.secondary)
            } else if filtered.isEmpty {
                emptyState
            } else {
                messageList
            }
        }
        .navigationTitle("Удалённые · \(peerName)")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Поиск...")
        .onAppear { reload() }
        .toolbar {
            ToolbarItem(placement: .destructiveAction) {
                if !messages.isEmpty {
                    Button(role: .destructive) {
                        DeletedMessagesCache.shared.clearAll()
                        reload()
                    } label: {
                        Image(systemName: "trash")
                    }
                }
            }
        }
    }

    // MARK: - Subviews

    private var messageList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(filtered) { msg in
                    DeletedMessageBubble(message: msg)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "trash.slash")
                .font(.system(size: 56))
                .foregroundColor(.secondary.opacity(0.5))
            Text("Удалённых и изменённых сообщений нет")
                .font(.headline)
                .foregroundColor(.secondary)
            Text("Когда кто-то удалит или изменит сообщение, оно сохранится здесь.")
                .font(.subheadline)
                .foregroundColor(.secondary.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }

    // MARK: - Data

    private func reload() {
        isLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let accountKey = DeletedMessagesCache.accountKey(forStoragePath: accountStoragePath)
            let result = DeletedMessagesCache.shared.deletedMessages(accountKey: accountKey, peerId: peerId)
            DispatchQueue.main.async {
                self.messages = result
                self.isLoading = false
            }
        }
    }
}

// MARK: - Message Bubble

struct DeletedMessageBubble: View {
    let message: DeletedMessage

    // Dates follow the language selected in Telegram, and re-resolve when it changes.
    // The device locale is only used before Telegram has a language at all.
    private static var cachedFormatter: (code: String, formatter: DateFormatter)?

    private static var dateFormatter: DateFormatter {
        let code = (UserDefaults.standard.string(forKey: "aorusgram_lang_code")
            ?? UserDefaults.standard.string(forKey: "aorusgram_lang")
            ?? Locale.preferredLanguages.first
            ?? Locale.current.identifier).lowercased()
        if let cached = Self.cachedFormatter, cached.code == code {
            return cached.formatter
        }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.locale = Locale(identifier: code)
        Self.cachedFormatter = (code, f)
        return f
    }

    private var statusColor: Color {
        if message.isDeleted { return Color(hex: "#EF5350") }   // red — deleted
        if message.isEdited  { return Color(hex: "#FFA726") }   // amber — edited
        return Color(hex: "#5C6BC0")
    }

    private var statusIcon: String {
        if message.isDeleted { return "trash.fill" }
        if message.isEdited  { return "pencil" }
        return "doc.text"
    }

    private var statusDate: Date {
        if message.isDeleted        { return message.deletedDate }
        if let ed = message.editedDate { return ed }
        return message.sentDate
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: message.isOutgoing ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                .foregroundColor(message.isOutgoing ? Color(hex: "#5C6BC0") : statusColor)
                .font(.system(size: 18))
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                // Header: sender + status badge
                HStack(spacing: 6) {
                    Text(message.senderName.isEmpty ? "Unknown" : message.senderName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.primary)

                    Spacer()

                    HStack(spacing: 3) {
                        Image(systemName: statusIcon)
                            .font(.system(size: 10))
                        Text(Self.dateFormatter.string(from: statusDate))
                            .font(.system(size: 11))
                    }
                    .foregroundColor(statusColor)
                }

                // Current text (after edit, or final-before-delete)
                if message.text.isEmpty {
                    if message.hasMedia {
                        Label("Медиафайл", systemImage: mediaIcon(for: message.mediaType))
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    } else {
                        Text("[пустое сообщение]")
                            .font(.system(size: 13, weight: .light))
                            .foregroundColor(.secondary)
                            .italic()
                    }
                } else {
                    Text(message.text)
                        .font(.system(size: 15))
                        .foregroundColor(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // For edits: show the original text below in a quote-style block.
                if message.isEdited, let original = message.originalText {
                    HStack(alignment: .top, spacing: 6) {
                        Rectangle()
                            .fill(Color(hex: "#FFA726"))
                            .frame(width: 2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Оригинал")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(Color(hex: "#FFA726"))
                            Text(original)
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.top, 4)
                }

                Text("Отправлено: \(Self.dateFormatter.string(from: message.sentDate))")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary.opacity(0.7))
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func mediaIcon(for type: String) -> String {
        switch type.lowercased() {
        case "photo":  return "photo.fill"
        case "video":  return "video.fill"
        case "audio", "voice": return "waveform"
        case "sticker": return "face.smiling.fill"
        default: return "paperclip"
        }
    }
}

// MARK: - Pinboard View

struct PinboardView: View {
    @ObservedObject private var store = PinboardStore.shared
    @State private var editingNote: PinnedMessage? = nil
    @State private var noteText = ""

    var body: some View {
        ZStack {
            AorusAnimatedBackground()

            if store.items.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(store.items) { item in
                            PinnedCard(item: item) {
                                editingNote = item
                                noteText = item.note
                            }
                            .contextMenu {
                                Button(role: .destructive) {
                                    PinboardManager.shared.unpin(id: item.id)
                                } label: {
                                    Label("Открепить", systemImage: "pin.slash.fill")
                                }
                            }
                        }
                    }
                    .padding(12)
                }
            }
        }
        .navigationTitle("Pinboard")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editingNote) { item in
            noteEditor(for: item)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "pin.slash")
                .font(.system(size: 56))
                .foregroundColor(.secondary.opacity(0.5))
            Text("Нет закреплённых сообщений")
                .font(.headline)
                .foregroundColor(.secondary)
            Text("Долгое нажатие на сообщение → «Закрепить в Pinboard»")
                .font(.subheadline)
                .foregroundColor(.secondary.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }

    private func noteEditor(for item: PinnedMessage) -> some View {
        NavigationView {
            ZStack {
                AorusAnimatedBackground()
                Form {
                    Section("Заметка к сообщению") {
                        TextEditor(text: $noteText)
                            .frame(minHeight: 100)
                    }
                    Section {
                        Text(item.text)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    } header: {
                        Text("Сообщение от \(item.senderName)")
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Редактировать заметку")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") {
                        PinboardManager.shared.updateNote(id: item.id, note: noteText)
                        editingNote = nil
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { editingNote = nil }
                }
            }
        }
    }
}

struct PinnedCard: View {
    let item: PinnedMessage
    let onEditNote: () -> Void

    private static let df: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label(item.peerName, systemImage: "bubble.left.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color(hex: "#FFA726"))
                    Spacer()
                    Text(Self.df.string(from: item.pinDate))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                Text(item.text)
                    .font(.system(size: 14))
                    .lineLimit(4)

                if !item.note.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "note.text")
                            .font(.system(size: 11))
                        Text(item.note)
                            .font(.system(size: 12))
                            .italic()
                    }
                    .foregroundColor(.secondary)
                }

                HStack {
                    Text("от \(item.senderName)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary.opacity(0.7))
                    Spacer()
                    Button(action: onEditNote) {
                        Image(systemName: "pencil")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(12)
        }
    }
}
