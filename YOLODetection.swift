import CoreGraphics
import Foundation

struct YOLODetection: Identifiable, Equatable {
    let id: UUID
    let classIndex: Int
    let className: String
    let score: Float
    let rect: CGRect

    /// Standard initializer - generates a new UUID
    init(classIndex: Int, className: String, score: Float, rect: CGRect) {
        self.id = UUID()
        self.classIndex = classIndex
        self.className = className
        self.score = score
        self.rect = rect
    }

    /// Initializer with stable ID for tracking
    init(id: UUID, classIndex: Int, className: String, score: Float, rect: CGRect) {
        self.id = id
        self.classIndex = classIndex
        self.className = className
        self.score = score
        self.rect = rect
    }

    static func == (lhs: YOLODetection, rhs: YOLODetection) -> Bool {
        lhs.classIndex == rhs.classIndex &&
            lhs.className == rhs.className &&
            lhs.score == rhs.score &&
            lhs.rect == rhs.rect
    }
}
