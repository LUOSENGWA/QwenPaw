/*
 * 设置页 —— HdsNavigation 路由（routerMap: settings）。
 * 内容：主题色（对齐 QwenPaw 控制台 6 预设）+ 关于与自检（MinePage）。
 * 主题切换即时生效：底部页签高亮色 + 沉浸光感手指光。
 */

import { HdsNavDestination } from '@kit.UIDesignKit';
import { common, Configuration, ConfigurationConstant } from '@kit.AbilityKit';
import { ThemeManager, ThemeSnapshot, ThemePreset, THEME_PRESETS } from '../theme/ThemeManager';
import { MinePage } from '../components/MinePage';

@Builder
export function SettingsPageBuilder(name: string, param: Object) {
  SettingsPage()
}

@Component
export struct SettingsPage {
  @State theme: ThemeSnapshot = ThemeManager.get().snapshot();
  @State isDark: boolean = false;

  aboutToAppear(): void {
    const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    this.isDark = ctx.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    ThemeManager.get().load(ctx).then(() => {
      this.theme = ThemeManager.get().snapshot();
    });
  }

  onConfigurationUpdate(newConfig: Configuration): void {
    this.isDark = newConfig.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
  }

  private async onPresetTap(preset: ThemePreset): Promise<void> {
    const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    const ok: boolean = await ThemeManager.get().selectPreset(preset.id, ctx);
    if (ok) {
      this.theme = ThemeManager.get().snapshot();
    }
  }

  @Builder
  presetSwatch(preset: ThemePreset) {
    Row() {
      Circle()
        .width(22)
        .height(22)
        .fill(this.isDark ? preset.accentDark : preset.accent)
        .stroke(this.theme.presetId === preset.id ? (this.isDark ? preset.accentDark : preset.accent) : $r('app.color.line'))
        .strokeWidth(this.theme.presetId === preset.id ? 3 : 1)
      Text(preset.name)
        .fontSize(14)
        .fontColor(this.theme.presetId === preset.id ? $r('app.color.text_primary_strong') : $r('app.color.text_secondary'))
        .margin({ left: 8 })
    }
    .width('100%')
    .padding(10)
    .borderRadius(12)
    .backgroundColor($r('app.color.card_surface'))
    .margin({ left: 4, right: 4, top: 5, bottom: 5 })
    .onClick(() => {
      this.onPresetTap(preset);
    })
  }

  build() {
    HdsNavDestination() {
      Scroll() {
        Column() {
          Text($r('app.string.settings_theme'))
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .margin({ top: 16, left: 20 })
          Text($r('app.string.settings_theme_hint'))
            .fontSize(12)
            .fontColor($r('app.color.text_tertiary'))
            .margin({ top: 6, left: 20, right: 20 })

          Column() {
            ForEach(THEME_PRESETS, (preset: ThemePreset) => {
              this.presetSwatch(preset)
            }, (preset: ThemePreset) => preset.id)
          }
          .width('100%')
          .padding(8)
          .borderRadius(16)
          .backgroundColor($r('app.color.page_bg'))
          .margin({ top: 12, left: 16, right: 16 })

          Divider().color($r('app.color.line')).margin({ top: 20 })

          MinePage()
        }
        .width('100%')
        .padding({ bottom: 32 })
      }
      .height('100%')
      .scrollBar(BarState.Auto)
    }
    .titleBar({
      content: {
        title: {
          mainTitle: $r('app.string.settings_title')
        }
      }
    })
  }
}
