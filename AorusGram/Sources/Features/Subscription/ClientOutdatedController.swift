import UIKit

// Non-dismissible root shown only for an authenticated server verdict
// `client_outdated`. The gate's opaque UIWindow remains above Telegram.
final class ClientOutdatedController: SubscriptionBaseController {
    var onUpdate: (() -> Void)?
    var onChannel: (() -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()

        addContent(SubscriptionStyle.centered(
            SubscriptionDuckView(duck: .outdated, renderSizePx: 384), size: 192
        ))
        addSpacing(4)
        addContent(SubscriptionStyle.title(SubL10n.outdatedTitle))
        addContent(SubscriptionStyle.body(SubL10n.outdatedBody))

        let update = SubscriptionStyle.primaryButton(SubL10n.updateApp)
        update.addTarget(self, action: #selector(updateTapped), for: .touchUpInside)
        addBottomButton(update)

        let channel = SubscriptionStyle.secondaryButton(SubL10n.openChannel)
        channel.addTarget(self, action: #selector(channelTapped), for: .touchUpInside)
        addBottomButton(channel)
    }

    @objc private func updateTapped() { onUpdate?() }
    @objc private func channelTapped() { onChannel?() }
}
