import Foundation

enum TestFailure: Error, CustomStringConvertible {
    case failed(String)
    var description: String {
        switch self {
        case .failed(let message): return message
        }
    }
}

func fail(_ message: String) throws {
    throw TestFailure.failed(message)
}

@discardableResult
func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws -> Bool {
    if !condition() {
        throw TestFailure.failed(message)
    }
    return true
}

func expectEqual<T: Equatable>(_ actual: @autoclosure () -> T, _ expected: @autoclosure () -> T, _ message: String) throws {
    let lhs = actual()
    let rhs = expected()
    if lhs != rhs {
        throw TestFailure.failed("\(message) (got: \(lhs), expected: \(rhs))")
    }
}

func expectNil<T>(_ value: @autoclosure () -> T?, _ message: String) throws {
    if value() != nil {
        throw TestFailure.failed(message)
    }
}

func expectNotNil<T>(_ value: @autoclosure () -> T?, _ message: String) throws {
    if value() == nil {
        throw TestFailure.failed(message)
    }
}
