//  MBWidgetBundle.swift
//  ManageBac 小组件 —— 12 个小组件的入口
//
//  两批：
//   ① 「单一主题」8 个（MBWidgetViews.swift）—— 待办 / 紧急度 / 倒计时 / 课表 / 成绩 / GPA / 概览 / 下一节
//   ② 「综合」4 个（MBWidgetMix.swift）—— 一屏同时看到「课（含倒计时）+ 待办 + 成绩」
//  一行一个种类，覆盖表盘复杂功能（圆形 / 圆角 / 行内 / 角标）与智能叠放。
//  全部共用 MBProvider（要的数据一样），并用 MBFamilyInjector 把系统的 widgetFamily
//  翻译成跨平台的 MBFamily 交给视图（这样版式自检工具在 Mac 上也能渲染同一套视图）。

import WidgetKit
import SwiftUI

@main
struct MBBundle: WidgetBundle {
    var body: some Widget {
        MBTodoWidget()
        MBBandCountWidget()
        MBCountdownWidget()
        MBScheduleWidget()
        MBScoreWidget()
        MBGPAWidget()
        MBDayWidget()
        MBNextClassWidget()
        MBAllInOneWidget()
        MBClassFocusWidget()
        MBGradeMixWidget()
        MBUrgentMixWidget()
    }
}

/* 1 ── 待办清单 */
struct MBTodoWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "mb.todo", provider: MBProvider()) { entry in
            MBFamilyInjector(content: MBTodoView(e: entry))
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("待办清单")
        .description("按剩余时间排好的待办，最急的排最上面。")
        .supportedFamilies([.accessoryRectangular, .accessoryCircular, .accessoryInline])
    }
}

/* 2 ── 待办紧急度 */
struct MBBandCountWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "mb.band", provider: MBProvider()) { entry in
            MBFamilyInjector(content: MBBandCountView(e: entry))
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("待办紧急度")
        .description("74 小时内到期的待办各有几项：红 26 小时、黄 50 小时、蓝 74 小时。")
        .supportedFamilies([.accessoryRectangular, .accessoryCircular, .accessoryInline])
    }
}

/* 3 ── 课堂倒计时 */
struct MBCountdownWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "mb.countdown", provider: MBProvider()) { entry in
            MBFamilyInjector(content: MBCountdownView(e: entry))
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("课堂倒计时")
        .description("上课时显示还有多久下课，课间显示还有多久上课。")
        .supportedFamilies([.accessoryRectangular, .accessoryCircular, .accessoryCorner, .accessoryInline])
    }
}

/* 4 ── 今日课表 */
struct MBScheduleWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "mb.schedule", provider: MBProvider()) { entry in
            MBFamilyInjector(content: MBScheduleView(e: entry))
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("今日课表")
        .description("正在上的那节和接下来两节；放学后自动显示下一个上课日。")
        .supportedFamilies([.accessoryRectangular, .accessoryCircular, .accessoryInline])
    }
}

/* 5 ── 最新成绩 */
struct MBScoreWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "mb.score", provider: MBProvider()) { entry in
            MBFamilyInjector(content: MBScoreView(e: entry))
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("最新成绩")
        .description("最近出分的作业：科目、作业名、等级与分数。")
        .supportedFamilies([.accessoryRectangular, .accessoryCircular, .accessoryInline])
    }
}

/* 6 ── GPA */
struct MBGPAWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "mb.gpa", provider: MBProvider()) { entry in
            MBFamilyInjector(content: MBGPAView(e: entry))
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("总均分 GPA")
        .description("各科总均分与满分 4 分的折算。")
        .supportedFamilies([.accessoryRectangular, .accessoryCircular, .accessoryCorner, .accessoryInline])
    }
}

/* 7 ── 今日概览 */
struct MBDayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "mb.day", provider: MBProvider()) { entry in
            MBFamilyInjector(content: MBDayView(e: entry))
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("今日概览")
        .description("今天几节课、在上的那节，以及最急的一项待办。")
        .supportedFamilies([.accessoryRectangular, .accessoryCircular, .accessoryInline])
    }
}

/* 8 ── 下一节课 */
struct MBNextClassWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "mb.next", provider: MBProvider()) { entry in
            MBFamilyInjector(content: MBNextClassView(e: entry))
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("下一节课")
        .description("下一节课的时间、教室、老师；上课时变成下课倒计时。")
        .supportedFamilies([.accessoryRectangular, .accessoryCircular, .accessoryInline])
    }
}

/* ============================================================
   9–12 ── 综合系列（MBWidgetMix.swift）
   一屏同时看到「接下来的课（与倒计时结合）+ 待办 + 最新成绩」
   ============================================================ */

/* 9 ── 学习总览：课 + 倒计时 ｜ 最急待办 ｜ 最新成绩 */
struct MBAllInOneWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "mb.allinone", provider: MBProvider()) { entry in
            MBFamilyInjector(content: MBMixView(e: entry))
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("学习总览")
        .description("三合一：距离下课/上课还有多久 + 最急的一项待办 + 最新出分。")
        .supportedFamilies([.accessoryRectangular, .accessoryCircular,
                            .accessoryCorner, .accessoryInline])
    }
}

/* 10 ── 课堂速览：倒计时大字 ｜ 接下来两节 ｜ 最急待办 */
struct MBClassFocusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "mb.classfocus", provider: MBProvider()) { entry in
            MBFamilyInjector(content: MBClassFocusView(e: entry))
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("课堂速览")
        .description("倒计时为主：正在上/下一节 + 之后两节的节次与时间 + 最急待办。")
        .supportedFamilies([.accessoryRectangular, .accessoryCircular, .accessoryInline])
    }
}

/* 11 ── 成绩速览：最新成绩两条 ｜ 距下课 + 待办数 */
struct MBGradeMixWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "mb.grademix", provider: MBProvider()) { entry in
            MBFamilyInjector(content: MBGradeMixView(e: entry))
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("成绩速览")
        .description("最新两条成绩，连同距离下课（上课）的时间与今日待办数量。")
        .supportedFamilies([.accessoryRectangular, .accessoryCircular, .accessoryInline])
    }
}

/* 12 ── 紧迫速览：倒计时 ｜ 红黄蓝 + 最急待办 ｜ 最新等级 */
struct MBUrgentMixWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "mb.urgentmix", provider: MBProvider()) { entry in
            MBFamilyInjector(content: MBUrgentMixView(e: entry))
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("紧迫速览")
        .description("倒计时 + 红黄蓝待办各有几项 + 最急的一项 + 最近一次的等级。")
        .supportedFamilies([.accessoryRectangular, .accessoryCircular,
                            .accessoryCorner, .accessoryInline])
    }
}
