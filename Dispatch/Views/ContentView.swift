// ContentView.swift
// Root host: the three-pane workbench shell. Theme + AppStores arrive via
// .environment from DispatchApp.

import SwiftUI

struct ContentView: View {
    var body: some View {
        WorkbenchView()
            // `.hiddenTitleBar` still reserves the ~28pt titlebar region as a top
            // safe-area inset, so the shell would start below an empty band (the
            // dominant header gap; an earlier topBarHeight trim never touched
            // it). Extend the content to the window's true
            // top edge so the rails run up under the floating traffic lights
            // (fullSizeContentView behavior). Clearance is the ProjectsRail's Row 1
            // titlebar strip (full-width, titleBarHeight tall, empty + non-
            // interactive): the lights float over it and stay clickable, and it
            // remains the window drag region. The brand row (Row 2) sits below it.
            .ignoresSafeArea(.container, edges: .top)
    }
}

#Preview {
    ContentView()
        .environment(Theme())
        .environment(AppStores.mock())
        .frame(width: 1440, height: 900)
}
