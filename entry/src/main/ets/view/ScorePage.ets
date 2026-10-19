/**
 * ScorePage — 成绩查询二级页面
 *
 * 学业情况（tab 页）内的「成绩查询」入口 / 首页快捷入口直达；
 * 内容复用 ScoreView（tab 原成绩页），showBack=true 显示返回按钮。
 */
import { ScoreView } from './ScoreView';

@Component
export struct ScorePage {
  build() {
    NavDestination() {
      ScoreView({ showBack: true })
    }
    .backgroundColor($r('app.color.bg_page'))
    .hideTitleBar(true)
    .systemTransition(NavigationSystemTransitionType.SLIDE_RIGHT)
  }
}
