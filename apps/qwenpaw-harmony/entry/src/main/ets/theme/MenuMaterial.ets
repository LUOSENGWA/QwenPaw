/*
 * 菜单的系统材质（统一出口）
 *
 * 官方《组件适配沉浸光感》：菜单属弹窗类组件/接口，systemMaterial 在**整个页面**均生效
 * （不像普通组件只限标题栏与 End 位置 TabBar）。故所有 bindMenu / bindContextMenu 统一走这里，
 * 档位取 THIN + interactive（按下有光感反馈）；注意设了 systemMaterial 后不要再设
 * backgroundColor / borderColor / borderWidth / shadow —— 它们会被材质覆盖（官方口径）。
 *
 * 半模态（bindSheet）另有统一出口 components/SheetGate.moduleSheetOptions（ULTRA_THICK 厚档）。
 */
import { uiMaterial } from '@kit.ArkUI';

export function menuMaterial(): uiMaterial.ImmersiveMaterial {
  return new uiMaterial.ImmersiveMaterial({
    style: uiMaterial.ImmersiveStyle.THIN,
    interactive: true
  });
}

export function menuOptions(): MenuOptions {
  return { systemMaterial: menuMaterial() };
}

export function contextMenuOptions(): ContextMenuOptions {
  return { enableArrow: true, systemMaterial: menuMaterial() };
}
