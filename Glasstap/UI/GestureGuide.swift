import SwiftUI

/// The gesture cheat sheet, shared by setup and settings.
enum GestureGuide {
    struct Item: Identifiable {
        let id: String
        let symbol: String
        let title: String
        let detail: String
        /// The setting that turns it on and off, if it can be.
        let setting: WritableKeyPath<GestureSettings, Bool>?
    }

    static let items: [Item] = [
        Item(id: "move", symbol: "hand.point.up.left", title: "Move your hand to move the pointer",
             detail: "Like a trackpad in the air: move slowly for precision, quickly to cross the screen.",
             setting: nil),
        Item(id: "click", symbol: "hand.pinch", title: "Pinch to click",
             detail: "Tap your thumb and index finger together. Pinch twice for a double-click.",
             setting: \.click),
        Item(id: "scroll", symbol: "arrow.up.and.down", title: "Pinch and move to scroll",
             detail: "Pinch, move your hand, let go. The page follows your hand, and keeps gliding if you flick.",
             setting: \.scroll),
        Item(id: "drag", symbol: "hand.draw", title: "Pinch and hold to drag",
             detail: "Pinch and hold still for half a second, then move. Let go to drop.",
             setting: \.drag),
        Item(id: "right", symbol: "cursorarrow.click.2", title: "Middle-finger pinch to right-click",
             detail: "Touch your thumb to your middle finger instead of your index finger.",
             setting: \.rightClick),
        Item(id: "zoom", symbol: "arrow.up.left.and.arrow.down.right", title: "Two-hand pinch to zoom",
             detail: "Pinch with both hands, then pull them apart to zoom in or together to zoom out.",
             setting: \.zoom),
        Item(id: "swipe", symbol: "hand.raised", title: "Open hand to pause and swipe",
             detail: "Spread your fingers and the pointer holds still, so you can reposition. Flick an open hand left or right to switch Spaces, up for Mission Control, down for the app's windows.",
             setting: \.swipe),
    ]
}

struct GestureRow: View {
    let item: GestureGuide.Item

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.symbol)
                .font(.system(size: 18))
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.headline)
                Text(item.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
