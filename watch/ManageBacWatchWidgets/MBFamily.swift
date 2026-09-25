//  MBFamily.swift
//  小组件的形态枚举（跨平台）
//
//  WidgetKit 的 `WidgetFamily.accessoryCircular / accessoryRectangular / accessoryInline /
//  accessoryCorner` 在 macOS 上被标为 unavailable，而版式自检工具要在 Mac 上把小组件
//  渲染出来核对，所以这里做一个中性枚举：
//    · 小组件运行时 —— MBFamilyInjector 把系统给的真实 widgetFamily 翻译成它；
//    · 自检工具 —— 直接注入想要核对的那种形态。
//
//  本文件是新建的，不属于「从 App 目录同步」的那批。

import SwiftUI
import WidgetKit

enum MBFamily: Equatable {
    case circular, rectangular, inline, corner, other

    init(_ wf: WidgetFamily) {
        #if os(watchOS)
        switch wf {
        case .accessoryCircular:    self = .circular
        case .accessoryRectangular: self = .rectangular
        case .accessoryInline:      self = .inline
        case .accessoryCorner:      self = .corner
        default:                    self = .other
        }
        #else
        self = .other
        #endif
    }
}

private struct MBFamilyKey: EnvironmentKey {
    static let defaultValue: MBFamily = .other
}

extension EnvironmentValues {
    var mbFamily: MBFamily {
        get { self[MBFamilyKey.self] }
        set { self[MBFamilyKey.self] = newValue }
    }
}
