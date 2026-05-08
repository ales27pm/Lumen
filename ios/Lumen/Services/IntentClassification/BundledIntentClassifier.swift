import CoreML
import Foundation
import NaturalLanguage

@MainActor
final class BundledIntentClassifier {
    static let shared = BundledIntentClassifier()
    private init() {}

    func classify(_ text: String) async -> IntentClassificationResult? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let nlModel = loadNLModel(),
           let label = nlModel.predictedLabel(for: trimmed),
           let intent = normalizeIntentLabel(label) {
            let probs = nlModel.predictedLabelHypotheses(for: trimmed, maximumCount: 5)
            let alternatives = probs.compactMap { normalizeIntentLabel($0.key).map { IntentAlternative(intent: $0, confidence: $1) } }.sorted { $0.confidence > $1.confidence }
            return IntentClassificationResult(intent: intent, confidence: probs[label] ?? 0.0, alternatives: alternatives, requiresClarification: false, clarificationPrompt: nil, source: .bundledModel, diagnostics: "nlmodel")
        }

        if let model = loadCoreMLModel(), let inferred = inferWithCoreML(model: model, text: trimmed) {
            return inferred
        }

        return nil
    }

    private func loadNLModel() -> NLModel? {
        guard let url = Bundle.main.url(forResource: "IntentClassifier", withExtension: "nlmodel") else { return nil }
        return try? NLModel(contentsOf: url)
    }

    private func loadCoreMLModel() -> MLModel? {
        if let compiledURL = Bundle.main.url(forResource: "IntentClassifier", withExtension: "mlmodelc") {
            return try? MLModel(contentsOf: compiledURL)
        }
        if let sourceURL = Bundle.main.url(forResource: "IntentClassifier", withExtension: "mlmodel"), let compiled = try? MLModel.compileModel(at: sourceURL) {
            return try? MLModel(contentsOf: compiled)
        }
        return nil
    }

    private func inferWithCoreML(model: MLModel, text: String) -> IntentClassificationResult? {
        guard let inputName = model.modelDescription.inputDescriptionsByName.keys.first else { return nil }
        let provider = try? MLDictionaryFeatureProvider(dictionary: [inputName: text])
        guard let provider, let output = try? model.prediction(from: provider) else { return nil }

        let label = (output.featureValue(for: "classLabel")?.stringValue) ?? (output.featureValue(for: "label")?.stringValue)
        guard let label, let intent = normalizeIntentLabel(label) else { return nil }

        let candidates = ["classProbability", "labelProbabilities", "probabilities"]
        var probs: [String: Double] = [:]
        for key in candidates {
            if let dict = output.featureValue(for: key)?.dictionaryValue as? [String: Double] {
                probs = dict
                break
            }
        }
        let alternatives = probs.compactMap { normalizeIntentLabel($0.key).map { IntentAlternative(intent: $0, confidence: $1) } }.sorted { $0.confidence > $1.confidence }
        let confidence = probs[label] ?? alternatives.first(where: { $0.intent == intent })?.confidence ?? 0.0
        return IntentClassificationResult(intent: intent, confidence: confidence, alternatives: alternatives, requiresClarification: false, clarificationPrompt: nil, source: .bundledModel, diagnostics: "coreml")
    }

    private func normalizeIntentLabel(_ raw: String) -> UserIntent? {
        let canonical = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .lowercased()
        if let exact = UserIntent(rawValue: raw) { return exact }
        return UserIntent.allCases.first { $0.rawValue.lowercased() == canonical }
    }
}
