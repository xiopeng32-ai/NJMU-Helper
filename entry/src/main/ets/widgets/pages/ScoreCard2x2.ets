/**
 * ScoreCard2x2 — 学业成绩桌面卡片（2x2 / 2x4）
 *
 * 数据来源（EntryFormAbility 推送，读本地学业缓存）：
 *  - GPA / 排名 / 已修学分 / 学期标签
 *  - 无缓存时显示引导文案，点击进入学业情况页
 *
 * 交互：点击整卡 → 打开「学业情况」页
 */

import { T } from '../../common/I18n';
let scoreStorage = new LocalStorage();

@Entry(scoreStorage)
@Component
struct ScoreCard2x2 {
  @LocalStorageProp('scoreGpa') scoreGpa: string = '--';
  @LocalStorageProp('scoreRank') scoreRank: string = '--';
  @LocalStorageProp('scoreCredit') scoreCredit: string = '--';
  @LocalStorageProp('scoreTerm') scoreTerm: string = '';
  @LocalStorageProp('scorePassRate') scorePassRate: string = '';
  @LocalStorageProp('hasScore') hasScore: boolean = false;
  @LocalStorageProp('lastRefresh') lastRefresh: string = '';

  private openAcademic(): void {
    postCardAction(this, {
      action: 'router',
      abilityName: 'EntryAbility',
      params: { open: 'academic' }
    });
  }

  build() {
    Column() {
      Row() {
        Text(T('学业成绩'))
          .fontSize(13)
          .fontWeight(FontWeight.Bold)
          .fontColor('#1A1D1C')
        Blank()
        Text(this.lastRefresh)
          .fontSize(8)
          .fontColor('#BBBBBB')
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      if (this.hasScore) {
        // GPA 主指标
        Row() {
          Text(this.scoreGpa)
            .fontSize(26)
            .fontWeight(FontWeight.Bold)
            .fontColor('#2C5FA8')
          Text('GPA')
            .fontSize(9)
            .fontColor('#888888')
            .margin({ left: 4, bottom: 4 })
        }
        .width('100%')
        .alignItems(VerticalAlign.Bottom)
        .margin({ top: 4 })

        if (this.scoreTerm.length > 0) {
          Text(this.scoreTerm)
            .fontSize(8)
            .fontColor('#999999')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }

        Divider()
          .color('#14000000')
          .margin({ top: 6, bottom: 5 })

        Row() {
          Column() {
            Text(this.scoreRank)
              .fontSize(12)
              .fontWeight(FontWeight.Medium)
              .fontColor('#1A1D1C')
            Text(T('排名'))
              .fontSize(8)
              .fontColor('#999999')
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)

          Column() {
            Text(this.scoreCredit)
              .fontSize(12)
              .fontWeight(FontWeight.Medium)
              .fontColor('#1A1D1C')
            Text(T('已修学分'))
              .fontSize(8)
              .fontColor('#999999')
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
      } else {
        Column() {
          Text(T('暂无成绩数据'))
            .fontSize(12)
            .fontColor('#999999')
          Text(T('登录并刷新后可查看'))
            .fontSize(9)
            .fontColor('#AAAAAA')
            .margin({ top: 3 })
          Text(T('点击打开学业情况'))
            .fontSize(9)
            .fontColor('#2C5FA8')
            .margin({ top: 6 })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      }
    }
    .width('100%')
    .height('100%')
    .padding(12)
    .backgroundColor('#F2FFFFFF')
    .borderRadius(16)
    .onClick(() => {
      this.openAcademic();
    })
  }
}
