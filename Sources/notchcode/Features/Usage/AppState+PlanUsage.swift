// AppState+PlanUsage.swift
// Plan usage for the Usage tool: Claude Code's usage cache in ~/.claude.json, refreshed by a
// headless `claude -p /usage` run 5 s after launch, every 15 minutes while Settings allows
// it, when the Usage pane shows and its cache is older than 5 minutes, and on R. Never in
// the demo.

import Foundation

extension AppState {

    static let planUsageNotFound = "claude command not found"
    static let planUsageFailed = "couldn't run claude"

    /// At launch (not in the demo): what the cache already holds, then the schedule.
    func startPlanUsage() {
        guard readsLocalFiles else { return }
        headlessIds.insert(PlanUsageRunner.sessionId())
        loadPlanUsageCache()
        schedulePlanUsage()
    }

    /// The first run after `planUsageLaunchDelay`, then one every `planUsageInterval`, while the pref is on.
    func schedulePlanUsage() {
        planUsageTask?.cancel()
        planUsageTask = nil
        guard readsLocalFiles, prefs.planUsageRefresh else { return }
        planUsageTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Theme.Timing.planUsageLaunchDelay))
            while !Task.isCancelled {
                self?.refreshPlanUsage(force: false)
                try? await Task.sleep(for: .seconds(Theme.Timing.planUsageInterval))
            }
        }
    }

    /// Settings → Usage: off stops the schedule, on starts it again.
    func planUsagePrefChanged() {
        schedulePlanUsage()
    }

    /// The Usage pane came on screen: pick up a newer cache (Claude Code writes it on every
    /// `/usage`), and refresh when it is stale.
    func usagePaneShown() {
        loadPlanUsageCache()
        refreshPlanUsage(force: false)
    }

    /// Reads the cache off the main thread and keeps it when it is newer than what is on hand.
    func loadPlanUsageCache() {
        guard readsLocalFiles else { return }
        Task { @MainActor [weak self] in
            let read = await Task.detached(priority: .utility) { PlanUsageReader.read() }.value
            guard let self else { return }
            if let read, read.fetchedAt > (self.planUsage?.fetchedAt ?? .distantPast) {
                self.planUsage = read
            }
            self.recomputeUsage()
        }
    }

    /// One `claude -p /usage` run. Not in the demo, not while one runs; unless forced (R),
    /// not with the pref off, not when the cache is younger than `planUsageStaleAfter`, and
    /// not again once no `claude` was found.
    func refreshPlanUsage(force: Bool) {
        guard readsLocalFiles, !planUsageRefreshing else { return }
        if !force {
            guard prefs.planUsageRefresh, planUsageNote != Self.planUsageNotFound else { return }
            if let fetched = planUsage?.fetchedAt, Date().timeIntervalSince(fetched) < Theme.Timing.planUsageStaleAfter { return }
        }
        // The run's own session must never surface, whatever reaches the app about it.
        headlessIds.insert(PlanUsageRunner.sessionId())
        planUsageRefreshing = true
        Task { @MainActor [weak self] in
            let result = await PlanUsageRunner.run(resolveAgain: force)
            guard let self else { return }
            self.planUsageRefreshing = false
            switch result {
            case .success(let text):
                self.planUsageNote = nil
                if let behaviors = PlanUsageReader.behaviors(fromResult: text) { self.usageBehaviors = behaviors }
                self.loadPlanUsageCache()
            case .failure(let error):
                self.planUsageNote = error == .notFound ? Self.planUsageNotFound : Self.planUsageFailed
            }
        }
    }
}
