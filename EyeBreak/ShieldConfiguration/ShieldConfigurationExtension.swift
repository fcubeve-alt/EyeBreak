import ManagedSettings
import ManagedSettingsUI
import UIKit

class ShieldConfigurationExtension: ShieldConfigurationDataSource {

    override func configuration(shielding application: Application) -> ShieldConfiguration {
        makeShieldConfig()
    }

    override func configuration(shielding application: Application,
                                in category: ActivityCategory) -> ShieldConfiguration {
        makeShieldConfig()
    }

    override func configuration(shielding webDomain: WebDomain) -> ShieldConfiguration {
        makeShieldConfig()
    }

    override func configuration(shielding webDomain: WebDomain,
                                in category: ActivityCategory) -> ShieldConfiguration {
        makeShieldConfig()
    }

    private func makeShieldConfig() -> ShieldConfiguration {
        let teal = UIColor(red: 0.08, green: 0.45, blue: 0.55, alpha: 1)

        return ShieldConfiguration(
            backgroundBlurStyle: .systemMaterialDark,
            backgroundColor: teal.withAlphaComponent(0.92),
            icon: UIImage(systemName: "eye.circle.fill")?
                .withTintColor(.white, renderingMode: .alwaysOriginal)
                .withConfiguration(UIImage.SymbolConfiguration(pointSize: 56)),
            title: ShieldConfiguration.Label(
                text: "眼睛需要休息了",
                color: .white
            ),
            subtitle: ShieldConfiguration.Label(
                text: "您已持续使用屏幕约30分钟\n请先做一下护眼动作 💚",
                color: UIColor.white.withAlphaComponent(0.88)
            ),
            primaryButtonLabel: ShieldConfiguration.Label(
                text: "做护眼动作",
                color: .white
            ),
            primaryButtonBackgroundColor: UIColor.white.withAlphaComponent(0.25),
            secondaryButtonLabel: ShieldConfiguration.Label(
                text: "稍后再说",
                color: UIColor.white.withAlphaComponent(0.55)
            )
        )
    }
}
