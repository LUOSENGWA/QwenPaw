/*
 * 通用工作台模块页 —— 路由 /module/{key}（对齐 PR #7378 app/module/[key].tsx 入口形态）。
 * 按模块 key 分派到具体设置组件（逐个对齐 7378 features/workbench/*），
 * 尚未移植的模块先展示模块能力范围与接口端点。
 */

import { HdsNavDestination, ScrollEffectType, BlurStrategy, hdsMaterial } from '@kit.UIDesignKit';
import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { WorkbenchModule, findWorkbenchModule } from '../services/WorkbenchModules';
import { ModuleOffload } from '../components/ModuleOffload';
import { ModuleAcp } from '../components/ModuleAcp';
import { ModuleAgentConfig } from '../components/ModuleAgentConfig';
import { ModuleAutomation } from '../components/ModuleAutomation';
import { ModuleChannels } from '../components/ModuleChannels';
import { ModuleCheckpoints } from '../components/ModuleCheckpoints';
import { ModuleSnapshot } from '../components/ModuleSnapshot';
import { ModuleDebug } from '../components/ModuleDebug';
import { ModuleFiles } from '../components/ModuleFiles';
import { ModuleProjectGit } from '../components/ModuleProjectGit';
import { ModuleTools } from '../components/ModuleTools';
import { ModuleVoice } from '../components/ModuleVoice';
import { ModuleSkills } from '../components/ModuleSkills';
import { ModuleSkillPool } from '../components/ModuleSkillPool';
import { ModuleMcpAcp } from '../components/ModuleMcpAcp';
import { ModuleEnvironments } from '../components/ModuleEnvironments';
import { ModuleSecurity } from '../components/ModuleSecurity';
import { ModuleOperations } from '../components/ModuleOperations';
import { ModuleModels } from '../components/ModuleModels';
import { ModuleExtensions } from '../components/ModuleExtensions';
import { ModuleHub } from '../components/ModuleHub';
import { ThemeManager, ThemeSnapshot } from '../theme/ThemeManager';
import { UiTokens } from '../theme/UiTokens';
import { LengthMetrics } from '@kit.ArkUI';

@Builder
export function ModulePageBuilder(_name: string, param: Object) {
  ModulePage({ params: param })
}

@Component
export struct ModulePage {
  params: Object = new Object();
  @State module: WorkbenchModule | null = null;
  @State theme: ThemeSnapshot = ThemeManager.get().snapshot();
  @State isDark: boolean = false;

  aboutToAppear(): void {
    const rec: Record<string, Object> = this.params as Record<string, Object>;
    const key: Object = rec['key'];
    const k: string = typeof key === 'string' ? key as string : '';
    this.module = findWorkbenchModule(k);
    const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    this.isDark = ctx.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    ThemeManager.get().load(ctx).then((): void => {
      this.theme = ThemeManager.get().snapshot();
      this.isDark = (ctx.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
    });
  }

  build() {
    HdsNavDestination() {
      Scroll() {
        Column() {
          if (this.module !== null) {
            Row() {
              Image(this.module!.icon)
                .width(26).height(26)
                .fillColor(this.isDark ? this.theme.accentDark : this.theme.accent)
                .margin({ right: 8 })
              Column() {
                Text(this.module!.title)
                  .fontSize(20)
                  .fontWeight(FontWeight.Bold)
                Text(this.module!.subtitle)
                  .fontSize(UiTokens.fsSecondary)
                  .fontColor($r('app.color.text_tertiary'))
                  .margin({ top: 2 })
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
            }
            .width('100%')
            .margin({ top: 16, bottom: 14 })

            if (this.module!.key === 'offload') {
              ModuleOffload()
            } else if (this.module!.key === 'acp') {
              ModuleAcp()
            } else if (this.module!.key === 'agent-config') {
              ModuleAgentConfig()
            } else if (this.module!.key === 'automation') {
              ModuleAutomation()
            } else if (this.module!.key === 'channels') {
              ModuleChannels()
            } else if (this.module!.key === 'checkpoints') {
              ModuleCheckpoints()
            } else if (this.module!.key === 'debug') {
              ModuleDebug()
            } else if (this.module!.key === 'files') {
              ModuleFiles()
            } else if (this.module!.key === 'projects-git') {
              ModuleProjectGit()
            } else if (this.module!.key === 'tools') {
              ModuleTools()
            } else if (this.module!.key === 'voice') {
              ModuleVoice()
            } else if (this.module!.key === 'skills') {
              ModuleSkills()
            } else if (this.module!.key === 'skill-pool') {
              ModuleSkillPool()
            } else if (this.module!.key === 'mcp-acp') {
              ModuleMcpAcp()
            } else if (this.module!.key === 'environments') {
              ModuleEnvironments()
            } else if (this.module!.key === 'security') {
              ModuleSecurity()
            } else if (this.module!.key === 'operations') {
              ModuleOperations()
            } else if (this.module!.key === 'models') {
              ModuleModels()
            } else if (this.module!.key === 'extensions') {
              ModuleExtensions()
            } else if (this.module!.key === 'hub') {
              ModuleHub()
            } else {
              // 尚未逐个移植设置项的模块：直接用该模块端点取真实数据（对齐 7378 SnapshotSettings）。
              // sessions 亦走此处：7378 该模块本身就是 /chats?archived=false 的通用视图。
              ModuleSnapshot({
                endpoint: this.module!.endpoint,
                icon: this.module!.icon
              })
            }
          }
        }
        .width('100%')
        .padding({
          top: UiTokens.topInset, bottom: 32,
          left: UiTokens.pageHMargin, right: UiTokens.pageHMargin
        })
      }
      .height('100%')
      .scrollBar(BarState.Auto)
      // 页面底色 + 扩绘制区到状态栏/导航栏：二级页根容器不自带底色时，标题栏以下与下带会露出窗口黑底（真机实测 (0,0,0)）
      .backgroundColor($r('app.color.page_bg'))
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    }
    // 内容也扩到安全区外（布局级）：官方 NavDestination.ignoreLayoutSafeArea，
    // 与 expandSafeArea 同时设置时它优先；前置条件要求标题栏隐藏或 STACK 模式
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
    .titleBar({
      // 二级页各自配标题栏（含返回图标区）：静止态即磨砂 + 系统转场动画。
      // 不开 systemMaterialEffect：官方《组件适配沉浸光感》称返回键在标题栏材质生效范围内，
      // 但该组合在 NavDestination 详情页会把整页渲染成纯黑（真机像素复核），故维持磨砂 + 静止态不滚动。
      style: {
        // 与主页同款沉浸：沉浸式渐变模糊 + 系统材质（等级 ADAPTIVE），静止态与滚动终点态都用主题色底。
        // 平台行为：深色下沉浸材质是"变暗玻璃"，会把底色压低（观感偏"透明"，属沉浸固有表现）。
        scrollEffectOpts: {
          // enableScrollEffect = false：官方口径「不随内容区滚动动态生效标题栏样式，仅生效 originalStyle」，
          // 且 GRADIENT_BLUR 下「直接生效模糊。此方式适用于列表型非沉浸式场景」。
          // 为什么不用 true：为 true 时样式会在 originalStyle→scrollEffectStyle 之间随滚动**插值**，
          // 上滚过程出现"先变暗、再慢慢回到主题色"的过渡观感（反复被报的"往上滑突然变黑然后慢慢
          // 出现主题色"）；关掉后底色/模糊只有一个状态，结构上不可能再出现滚动时变色。
          // 标题栏随滚动收起（titleMode FREE）与内容穿过时的模糊都不受影响。
          enableScrollEffect: false,
          scrollEffectType: ScrollEffectType.GRADIENT_BLUR
        },
        // blurStrategy 用 ENABLE 而不是 ADAPTIVE：官方口径 ADAPTIVE「根据系统策略调整…只有精美档位
        // 配置能够生效模糊效果」—— 系统策略落在轻柔/流畅档时标题栏模糊整块不生效，内容滚过时就露出
        // 未模糊的暗色内容（观感即"往上滑突然变黑"）；ENABLE 恒生效，观感才稳定。
        blurStrategy: BlurStrategy.ENABLE,
        originalStyle: {
          backgroundStyle: {
            blurRadius: 12.0,
            // 蒙层外扩必须写在**生效态**里：enableScrollEffect=false 时只生效 originalStyle，
            // 写在 scrollEffectStyle 里会被忽略、退回平台默认外扩（真机实测蒙层 822 → 标题栏底边
            // 710 之下多出 112px≈56vp），那段在工具条正下方留下一条中性灰带（浅色模式即"接缝"）；
            // 归零后蒙层与标题栏同底（710），渐隐在标题栏内完成，内容区不再被蒙层压到。
            maskExtraHeight: 0.0,
            backgroundColor: this.isDark ? this.theme.accentDark : this.theme.accent
          }
        },
        scrollEffectStyle: {
          backgroundStyle: {
            blurRadius: 12.0,
            backgroundColor: this.isDark ? this.theme.accentDark : this.theme.accent
          }
        },
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.ADAPTIVE,
          materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
        }
      },
      content: {
        title: {
          mainTitle: this.module !== null ? this.module!.title : $r('app.string.tab_workbench')
        }
      },
      // 与主页一致：标题栏不避让安全区向上铺到状态栏区域，组件安全区关闭（否则状态栏带露系统底）
      avoidLayoutSafeArea: false,
      enableComponentSafeArea: false
    })
  }

  private t(res: Resource): string {
    try {
      const host: common.Context = this.getUIContext().getHostContext() as common.Context;
      return host.resourceManager.getStringSync(res.id);
    } catch (e) {
      return '';
    }
  }
}
