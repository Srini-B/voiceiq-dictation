import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @State private var onboarded = MobileSettings.hasCompletedOnboarding
    @State private var tab = Tab.home
    @State private var showKeyboardSetup = false

    enum Tab { case home, history, meetings, settings }

    var body: some View {
        Group {
            if onboarded {
                TabView(selection: $tab) {
                    HomeView(tab: $tab)
                        .tabItem { Label("Home", systemImage: "waveform") }
                        .tag(Tab.home)
                    HistoryView()
                        .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
                        .tag(Tab.history)
                    MeetingsView()
                        .tabItem { Label("Notes", systemImage: "record.circle") }
                        .tag(Tab.meetings)
                    SettingsView()
                        .tabItem { Label("Settings", systemImage: "gearshape") }
                        .tag(Tab.settings)
                }
                .modifier(MinimizeTabBarOnScroll())
            } else {
                OnboardingView {
                    MobileSettings.hasCompletedOnboarding = true
                    withAnimation { onboarded = true }
                }
            }
        }
        .overlay {
            if model.showSwipeBack {
                SwipeBackView()
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .top) {
            if let banner = model.banner {
                BannerView(text: banner) { model.banner = nil }
                    .padding(.horizontal, Theme.Spacing.page)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.showSwipeBack)
        .animation(.easeInOut(duration: 0.2), value: model.banner)
        .sheet(isPresented: $showKeyboardSetup) {
            NavigationStack { KeyboardSetupView() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .voiceIQShowKeyboardSetup)) { _ in
            if onboarded { showKeyboardSetup = true }
        }
    }
}

/// Shown after the one-time trip to the app when iOS gave no way back to the
/// app the user came from.
struct SwipeBackView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack {
            Theme.Colors.canvas.ignoresSafeArea()
            VStack(spacing: Theme.Spacing.xl) {
                Spacer()
                ZStack {
                    Circle().fill(Theme.Colors.recording.opacity(0.12)).frame(width: 132, height: 132)
                    BrandMark(size: 84)
                }
                VStack(spacing: Theme.Spacing.s) {
                    Text("Listening").font(Theme.Fonts.title()).foregroundStyle(Theme.Colors.ink)
                    Text("Swipe right along the bottom edge to go back and keep talking.")
                        .font(Theme.Fonts.callout())
                        .foregroundStyle(Theme.Colors.muted)
                        .multilineTextAlignment(.center)
                }
                Spacer()
                SwipeHint().padding(.bottom, 28)
            }
            .padding(Theme.Spacing.xxl)
        }
        .onTapGesture { model.showSwipeBack = false }
    }
}

private struct SwipeHint: View {
    @State private var offset: CGFloat = -60

    var body: some View {
        Capsule()
            .fill(Theme.Colors.ink.opacity(0.25))
            .frame(width: 140, height: 5)
            .overlay(alignment: .leading) {
                Image(systemName: "hand.point.up.left.fill")
                    .font(.title)
                    .foregroundStyle(Theme.Colors.accent)
                    .offset(x: offset + 50, y: -26)
            }
            .onAppear {
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: false)) { offset = 60 }
            }
    }
}

struct BannerView: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.m) {
            BrandMark(size: 22)
            Text(text).font(Theme.Fonts.subheadline()).foregroundStyle(Theme.Colors.ink)
            Spacer(minLength: Theme.Spacing.s)
            Button(action: dismiss) {
                Image(systemName: "xmark").font(.system(size: 12, weight: .bold))
                    .frame(width: 24, height: 24)
            }
            .foregroundStyle(Theme.Colors.muted)
            .accessibilityLabel("Dismiss")
        }
        .padding(Theme.Spacing.m)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.Colors.surface)
            .shadow(color: .black.opacity(0.12), radius: 16, y: 6))
        .task {
            try? await Task.sleep(for: .seconds(5))
            dismiss()
        }
    }
}

/// The iPhone's bottom tab bar shrinks while the page scrolls down. iPadOS
/// ignores it: its tab bar sits at the top.
private struct MinimizeTabBarOnScroll: ViewModifier {
    /// Enables tab bar minimization on downward scrolling on iOS 26 and later,
    /// returning the content unchanged on earlier versions.
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.tabBarMinimizeBehavior(.onScrollDown)
        } else {
            content
        }
    }
}
