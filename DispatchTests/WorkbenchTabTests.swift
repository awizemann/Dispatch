// WorkbenchTabTests.swift
// Nav order and the title/rawValue decoupling. The `rawValue` is the STABLE id
// and the DEBUG `--tab=` key — it must NOT drift when a display name changes.
// P2 pruned the workbench to the Messages tab (the Projects rail is not a tab);
// P5 re-populates this as the new product's shell lands.

import Testing
@testable import DispatchApp

@Suite("Workbench tab")
struct WorkbenchTabTests {

    @Test("nav order is Messages (by title)")
    func navOrderByTitle() {
        #expect(WorkbenchTab.allCases.map(\.title) == ["Messages"])
    }

    @Test("rawValue keys stay stable — the DEBUG --tab= contract does not drift")
    func rawValueStability() {
        #expect(WorkbenchTab.allCases.map(\.rawValue) == ["Messages"])
        // id mirrors rawValue (the stable identity).
        #expect(WorkbenchTab.allCases.map(\.id) == WorkbenchTab.allCases.map(\.rawValue))
    }

    @Test("every case's title equals its rawValue")
    func titlesMatchRawValues() {
        for tab in WorkbenchTab.allCases {
            #expect(tab.title == tab.rawValue)
        }
    }

    @Test("Messages is reachable by the --tab=Messages key")
    func messagesCaseReachable() {
        #expect(WorkbenchTab(rawValue: "Messages") == .messages)
    }
}
