// Panel registry. Adding a tool means writing one module in ui/panels/ and
// adding one import here -- that is the whole extension point. The sidebar
// lists panels in this order under their group, which is also the Ctrl+1..9
// order. Settings is not a panel: it is a sidebar view, as in the Crew Deck,
// because the Operations webview covers its tile and would hide an overlay.
//
// A panel module's default export:
//
//   {
//     id, label,
//     hint,            one line under the label in the sidebar: what you go there to do
//     icon,            a name from lib/icons.js
//     group,           "Hosts" | "Business"
//     requiresHosts,   true if it is useless without hosts in config.json
//     single,          true if only one tile may show it (Operations: one webview)
//     mount(ctx) -> { destroy?(), layout?() }
//   }
//
// mount() is called once per tile and owns ctx.body until destroy(). The
// shell never re-renders a panel: a surviving tile keeps its DOM, so state
// lives in the panel's closure. ctx:
//
//   body      the tile body element (scrolls; padded)
//   tools     a slot in the tile header, before split/zoom/close, for the
//             panel's own controls (host picker, refresh, filter)
//   info      AppInfo from the backend
//   setMeta(text)    the faint text beside the tile's panel picker
//   confirm(ask)     ask before a destructive action; resolves true to go on.
//                    ask = { title, why?, command, host?, danger?, action? (button label, default "Run"), run: async () => {} }
//                    The command (or reviewed diff) is shown verbatim, never paraphrased.
//                    It is drawn inside the tile, not over the window.
//   covered()        true while another tile is zoomed over this one
//
// layout() is called after anything that may move or resize the tile.

import hosts from "../panels/hosts.js";
import operations from "../panels/operations.js";
import dispatch from "../panels/dispatch.js";
import procurement from "../panels/procurement.js";

// Business first: that is the work. Health, Services, Scripts and Configs are
// tabs of the one Hosts panel (panels/hosts.js).
export const PANELS = [operations, dispatch, procurement, hosts];
export const GROUPS = ["Business", "Hosts"];

export const panelById = (id) => PANELS.find((p) => p.id === id) ?? PANELS[0];
