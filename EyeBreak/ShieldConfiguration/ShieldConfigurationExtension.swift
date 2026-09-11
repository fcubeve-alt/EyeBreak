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
            // 阈值用户可调，文案必须按实际值生成，不能写死「30 分钟」
            subtitle: ShieldConfiguration.Label(
                text: UserDefaults.eyeBreak.eb_triggerSubtitle,
                color: UIColor.white.withAlphaComponent(0.88)
            ),
            // iOS 不允许扩展直接拉起主 App，所以按钮文案如实说明下一步：
            // 点击后解除遮罩并推送一条可一键进入护眼动作的通知。
            primaryButtonLabel: ShieldConfiguration.Label(
                text: "解除并发送护眼提醒",
                color: .white
            ),
            primaryButtonBackgroundColor: UIColor.white.withAlphaComponent(0.25),
            secondaryButtonLabel: ShieldConfiguration.Label(
                text: "稍后再说",
                color: UIColor.white.withAlphaComponent(0.75)
            )
        )
    }
}
