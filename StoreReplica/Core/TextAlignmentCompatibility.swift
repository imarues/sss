import SwiftUI

// Compatibility shim for LTR fields inside the otherwise RTL interface.
// SwiftUI uses `.leading` / `.trailing`; keeping `.left` available lets
// the signing hub express a physically-left aligned URL field without
// changing the surrounding Turath-style RTL layout.
extension TextAlignment {
    static var left: TextAlignment { .leading }
}
