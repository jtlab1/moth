import Charts
import MeasurementCore
import SwiftUI

/// The room's name is the navigation title, so the screen doesn't repeat it.
public struct RoomDetailView: View {
    let summary: RoomSummary
    @Binding var fixtureType: FixtureType
    @Binding var notes: String
    @Binding var copingStrategies: Set<CopingStrategy>
    let customCopingStrategies: [CustomCopingStrategy]
    @Binding var customCopingStrategyIDs: Set<UUID>
    let onAddCustomCopingStrategy: (String) -> Void
    let onDeleteCustomCopingStrategy: (UUID) -> Void
    let onMeasure: () -> Void
    let onAssignBuilding: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void

    @Environment(\.mothPalette) private var palette
    @State private var showsDepthChart = false
    @State private var isAddingCustomStrategy = false
    @State private var newCustomStrategyTitle = ""
    @FocusState private var isCustomStrategyFieldFocused: Bool

    public init(
        summary: RoomSummary,
        fixtureType: Binding<FixtureType>,
        notes: Binding<String>,
        copingStrategies: Binding<Set<CopingStrategy>>,
        customCopingStrategies: [CustomCopingStrategy],
        customCopingStrategyIDs: Binding<Set<UUID>>,
        onAddCustomCopingStrategy: @escaping (String) -> Void,
        onDeleteCustomCopingStrategy: @escaping (UUID) -> Void,
        onMeasure: @escaping () -> Void,
        onAssignBuilding: @escaping () -> Void,
        onRename: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.summary = summary
        self._fixtureType = fixtureType
        self._notes = notes
        self._copingStrategies = copingStrategies
        self.customCopingStrategies = customCopingStrategies
        self._customCopingStrategyIDs = customCopingStrategyIDs
        self.onAddCustomCopingStrategy = onAddCustomCopingStrategy
        self.onDeleteCustomCopingStrategy = onDeleteCustomCopingStrategy
        self.onMeasure = onMeasure
        self.onAssignBuilding = onAssignBuilding
        self.onRename = onRename
        self.onDelete = onDelete
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(subtitle)
                    .font(.body)
                    .foregroundStyle(palette.secondaryText)
                    .padding(.horizontal, 4)
                statusCard.mothAppear()
                copingStrategiesCard.mothAppear(delay: 0.06)
                if !summary.measurements.isEmpty {
                    historyCard.mothAppear(delay: 0.12)
                }
                detailsCard.mothAppear(delay: 0.18)
            }
            .padding(MothTheme.sectionSpacing)
            .animation(MothTheme.Motion.smooth, value: summary.measurements.map(\.id))
        }
        .scrollDismissesKeyboard(.interactively)
        .mothScreenBackground()
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        onRename()
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        onDelete()
                    } label: {
                        Label("Delete room", systemImage: "trash")
                    }
                } label: {
                    Label("Room options", systemImage: "ellipsis.circle")
                }
            }
        }
    }

    private var subtitle: String {
        guard let latest = summary.latest else { return summary.buildingName }
        return "\(summary.buildingName) · checked \(latest.capturedAt.formatted(date: .abbreviated, time: .omitted))"
    }

    // MARK: - Status

    private var statusCard: some View {
        MothCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    MothStatusSymbol(severity: summary.severity, size: .title2)
                    Text(summary.latest == nil ? "Not measured yet" : summary.severity.title)
                        .font(.moth(.title3, weight: .heavy))
                        .foregroundStyle(palette.primaryText)
                }
                .accessibilityElement(children: .combine)

                if let overallTrendSummary {
                    Text(overallTrendSummary)
                        .font(.body)
                        .foregroundStyle(palette.secondaryText)
                }

                Button("Measure this room") { onMeasure() }
                    .buttonStyle(.mothPrimary)
            }
        }
    }

    private var overallTrendSummary: String? {
        guard let latest = summary.measurements.first,
              let oldest = summary.measurements.last,
              latest.id != oldest.id
        else { return nil }
        let sinceDate = oldest.capturedAt.formatted(date: .abbreviated, time: .omitted)
        switch latest.trend(since: oldest) {
        case .worse: return "Trending worse since \(sinceDate)."
        case .better: return "Trending better since \(sinceDate)."
        case .unchanged: return "Holding steady since \(sinceDate)."
        }
    }

    // MARK: - Coping strategies

    /// What the user says they do here, not guidance the app asserts.
    private var copingStrategiesCard: some View {
        MothCard {
            VStack(alignment: .leading, spacing: 14) {
                MothSectionHeader("What helps here", subtitle: "Tap what you do in this room. Just for you.")
                MothFlowLayout(spacing: 8) {
                    ForEach(CopingStrategy.allCases) { strategy in
                        copingStrategyPill(strategy)
                    }
                    ForEach(customCopingStrategies) { strategy in
                        customCopingStrategyPill(strategy)
                    }
                    if !isAddingCustomStrategy {
                        addCustomStrategyPill
                    }
                }
                if isAddingCustomStrategy {
                    addCustomStrategyField
                        .transition(.mothSwap)
                }
            }
            .animation(MothTheme.Motion.smooth, value: isAddingCustomStrategy)
            .animation(MothTheme.Motion.smooth, value: customCopingStrategies.map(\.id))
        }
    }

    private func customCopingStrategyPill(_ strategy: CustomCopingStrategy) -> some View {
        let isChecked = customCopingStrategyIDs.contains(strategy.id)
        return strategyPill(title: strategy.title, isChecked: isChecked) {
            if isChecked {
                customCopingStrategyIDs.remove(strategy.id)
            } else {
                customCopingStrategyIDs.insert(strategy.id)
            }
        }
        .contextMenu {
            Button(role: .destructive) {
                onDeleteCustomCopingStrategy(strategy.id)
            } label: {
                Label("Delete From All Rooms", systemImage: "trash")
            }
        }
        .accessibilityHint(Text("Touch and hold to delete."))
    }

    private var addCustomStrategyPill: some View {
        let shape = Capsule()
        return Button {
            isAddingCustomStrategy = true
            isCustomStrategyFieldFocused = true
        } label: {
            Label("Add your own", systemImage: "plus")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(palette.accent)
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .overlay(shape.strokeBorder(palette.accent, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                .contentShape(shape)
        }
        .buttonStyle(.mothPressable)
    }

    private var addCustomStrategyField: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("e.g. \"Sit facing the window\"", text: $newCustomStrategyTitle)
                .mothField()
                .focused($isCustomStrategyFieldFocused)
                .submitLabel(.done)
                .onSubmit(submitCustomStrategy)
                .onChange(of: newCustomStrategyTitle) { _, newValue in
                    if newValue.count > CustomCopingStrategy.maximumTitleLength {
                        newCustomStrategyTitle = String(newValue.prefix(CustomCopingStrategy.maximumTitleLength))
                    }
                }
            HStack(spacing: 10) {
                Button("Cancel") { endAddingCustomStrategy() }
                    .buttonStyle(.mothSecondary)
                Button("Add") { submitCustomStrategy() }
                    .buttonStyle(.mothPrimary)
                    .disabled(CustomCopingStrategy.normalizedTitle(newCustomStrategyTitle) == nil)
            }
        }
    }

    /// A built-in's name checks the built-in instead of making a custom duplicate.
    private func submitCustomStrategy() {
        guard let title = CustomCopingStrategy.normalizedTitle(newCustomStrategyTitle) else { return }
        if let builtIn = CopingStrategy.allCases.first(where: {
            $0.title.localizedCaseInsensitiveCompare(title) == .orderedSame
        }) {
            copingStrategies.insert(builtIn)
        } else {
            onAddCustomCopingStrategy(title)
        }
        endAddingCustomStrategy()
    }

    private func endAddingCustomStrategy() {
        newCustomStrategyTitle = ""
        isCustomStrategyFieldFocused = false
        isAddingCustomStrategy = false
    }

    private func copingStrategyPill(_ strategy: CopingStrategy) -> some View {
        let isChecked = copingStrategies.contains(strategy)
        return strategyPill(title: strategy.title, isChecked: isChecked) {
            if isChecked {
                copingStrategies.remove(strategy)
            } else {
                copingStrategies.insert(strategy)
            }
        }
    }

    private func strategyPill(title: String, isChecked: Bool, action: @escaping () -> Void) -> some View {
        let shape = Capsule()
        return Button(action: action) {
            HStack(spacing: 6) {
                if isChecked {
                    Image(systemName: "checkmark")
                        .font(.footnote.weight(.bold))
                }
                Text(title)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(isChecked ? palette.onAccent : palette.primaryText)
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .background(isChecked ? palette.accent : palette.accentSoft, in: shape)
            .overlay(shape.strokeBorder(isChecked ? palette.accent : palette.cardBorder, lineWidth: 1))
        }
        .buttonStyle(.mothPressable)
        .sensoryFeedback(.selection, trigger: isChecked)
        .accessibilityAddTraits(isChecked ? .isSelected : [])
    }

    // MARK: - History

    private var historyCard: some View {
        MothCard {
            VStack(alignment: .leading, spacing: 4) {
                MothSectionHeader("History")
                    .padding(.bottom, 6)

                ForEach(Array(summary.measurements.enumerated()), id: \.element.id) { index, measurement in
                    let previous = index + 1 < summary.measurements.count ? summary.measurements[index + 1] : nil
                    if index > 0 {
                        Divider().overlay(palette.divider)
                    }
                    historyRow(measurement, previous: previous)
                }

                if depthChartMeasurements.count >= 2 {
                    DisclosureGroup(isExpanded: $showsDepthChart) {
                        depthChart.padding(.top, 8)
                    } label: {
                        Text("Depth over time")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(palette.accent)
                            .frame(minHeight: 44)
                    }
                    .tint(palette.accent)
                    .padding(.top, 4)
                }
            }
        }
    }

    /// The summary line reads as one VoiceOver element; the disclosure stays separately operable.
    private func historyRow(_ measurement: RoomMeasurement, previous: RoomMeasurement?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            historySummary(measurement, previous: previous)
            CaptureDetailsDisclosure(flicker: measurement.flicker, includesNotes: true)
                .padding(.leading, 22)
                .padding(.bottom, 4)
        }
    }

    private func historySummary(_ measurement: RoomMeasurement, previous: RoomMeasurement?) -> some View {
        HStack(alignment: .center, spacing: 12) {
            SeverityDot(severity: measurement.flicker.severity)
            VStack(alignment: .leading, spacing: 3) {
                Text(measurement.capturedAt, style: .date)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(palette.primaryText)
                Text(historyDetail(measurement))
                    .font(.subheadline)
                    .foregroundStyle(palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if let previous, let change = comparisonText(current: measurement, previous: previous) {
                    Text(change)
                        .font(.footnote)
                        .foregroundStyle(palette.secondaryText)
                }
            }
            Spacer(minLength: 8)
            if let rating = measurement.comfortRating {
                Text("Felt \(rating)/5")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(palette.secondaryText)
            }
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    private func historyDetail(_ measurement: RoomMeasurement) -> String {
        var parts = [measurement.flicker.verdict?.title ?? measurement.flicker.presence.title]
        if let frequency = measurement.flicker.formattedFrequency { parts.append(frequency) }
        if let depth = measurement.flicker.formattedModulationDepth { parts.append(depth) }
        return parts.joined(separator: " · ")
    }

    /// Nothing when unchanged: "same as last time" on every row is noise.
    private func comparisonText(current: RoomMeasurement, previous: RoomMeasurement) -> String? {
        if let delta = current.modulationDepthChange(since: previous) {
            guard abs(delta) >= 0.05 else { return nil }
            return String(format: "%@%.1f pts vs. last reading", delta > 0 ? "+" : "", delta)
        }
        let trend = current.trend(since: previous)
        return trend == .unchanged ? nil : trend.title
    }

    /// Depth only, so every point on the line means the same thing.
    private var depthChartMeasurements: [RoomMeasurement] {
        summary.measurements
            .filter { $0.flicker.modulationDepthPercent != nil }
            .sorted { $0.capturedAt < $1.capturedAt }
    }

    private var depthChart: some View {
        Chart(depthChartMeasurements) { measurement in
            LineMark(
                x: .value("Date", measurement.capturedAt),
                y: .value("Modulation depth", measurement.flicker.modulationDepthPercent ?? 0)
            )
            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
            .foregroundStyle(palette.accent)
            PointMark(
                x: .value("Date", measurement.capturedAt),
                y: .value("Modulation depth", measurement.flicker.modulationDepthPercent ?? 0)
            )
            .symbolSize(36)
            .foregroundStyle(palette.accent)
        }
        .chartXAxis(.hidden)
        .chartYAxisLabel("Depth %")
        .frame(height: 120)
    }

    // MARK: - Details

    private var detailsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Light type")
                    .foregroundStyle(palette.primaryText)
                Spacer()
                Picker("Light type", selection: $fixtureType) {
                    ForEach(FixtureType.allCases) { type in
                        Text(type.title).tag(type)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .tint(palette.secondaryText)
            }
            .font(.body)
            .padding(.horizontal, MothTheme.cardPadding)
            .frame(minHeight: 56)

            Divider().overlay(palette.divider).padding(.leading, MothTheme.cardPadding)

            Button {
                onAssignBuilding()
            } label: {
                HStack {
                    Text("Building")
                        .foregroundStyle(palette.primaryText)
                    Spacer()
                    Text(summary.room.buildingID == nil ? "Add" : summary.buildingName)
                        .foregroundStyle(palette.secondaryText)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(palette.secondaryText.opacity(0.7))
                }
                .font(.body)
                .padding(.horizontal, MothTheme.cardPadding)
                .frame(minHeight: 56)
                .contentShape(Rectangle())
            }
            .buttonStyle(.mothPressable)

            Divider().overlay(palette.divider).padding(.leading, MothTheme.cardPadding)

            VStack(alignment: .leading, spacing: 8) {
                Text("Notes")
                    .font(.body)
                    .foregroundStyle(palette.primaryText)
                TextField("e.g. \"Worst by the window end\"", text: $notes, axis: .vertical)
                    .lineLimit(3...6)
                    .mothField()
            }
            .padding(MothTheme.cardPadding)
        }
        .background(palette.cardBackground, in: RoundedRectangle(cornerRadius: MothTheme.cardCornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: MothTheme.cardCornerRadius, style: .continuous).strokeBorder(palette.cardBorder, lineWidth: 1))
    }
}
