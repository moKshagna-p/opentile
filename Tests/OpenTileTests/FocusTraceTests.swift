import Testing
@testable import AppBundle

struct FocusTraceTests {
    @Test func contextIsRestoredAfterFailure() {
        enum Failure: Error { case expected }
        do {
            try FocusTrace.$current.withValue(FocusTrace.make(enabled: true)) {
                #expect(FocusTrace.current != nil)
                throw Failure.expected
            }
            Issue.record("Expected the trace operation to throw")
        } catch {}
        #expect(FocusTrace.current == nil)
    }

    @Test func disabledTracingHasNoContext() async {
        #expect(FocusTrace.make(enabled: false) == nil)
        #expect(FocusTrace.current == nil)
        await FocusTrace.$current.withValue(FocusTrace.make(enabled: true)) {
            #expect(FocusTrace.current != nil)
            let inherited = await Task { FocusTrace.current != nil }.value
            #expect(inherited)
            FocusTrace.$current.withValue(nil) {
                #expect(FocusTrace.current == nil)
            }
            #expect(FocusTrace.current != nil)
        }
        #expect(FocusTrace.current == nil)
    }
}
