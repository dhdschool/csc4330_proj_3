# Playing Le Truc

Open project.godot in Godot 4.7 and press F5 (Run Project).
Choose Local Play. Two players share the computer, passing it at each player change.
The incoming player selects Reveal my hand. Choose a card during the play phase;
use the other buttons to keep/request a deal, negotiate stakes, or concede.
The match ends at 12 points and offers Play again. Online Play connects two
computers: one player hosts (UDP port 24565), the other enters the host's
address and joins. Each screen shows only its own hand.

The original rules in components/game.gd are unchanged.

## Team handoff

- ui/main.tscn is the configured main scene.
- ui/main.gd builds the interface. CARD_ART maps NINE, TEN, VALET, DAME, ROI,
  ACE, EIGHT, SEVEN to card-1.png through card-8.png respectively. Hand and tutorial
  Buttons show the artwork above the original rank/suit caption; card-9.png is
  unused. The callback _act("play_card", hand_index), rank/suit enums, and session
  data remain unchanged.
- ui/local_session.gd owns the rules instance and exposes plain-data snapshots and
  validated commands. changed tells the interface to refresh after rules advance.
- test_ui.gd drives complete matches through the UI action path and checks stale
  commands, wrong-seat commands, spectator hand privacy, and match restarts.

## Networking integration

Built on the p2p layer in components/multiplayer/. server.gd is the
authoritative host: it owns the Game, assigns seats from peer ids (a client
can never act for its opponent), and pushes a per-seat snapshot after every
game signal. Hands are private; the opponent travels as a card count. Actions
go Client -> s_action over reliable RPC and are validated against the seat's
legal actions; revision numbers reject stale or duplicate commands.

ui/online_session.gd is the online counterpart of ui/local_session.gd: it
maps the wire snapshot onto the local session contract (fixed seat,
revision-guarded submit) so main.gd renders online play with the same code
as local play. Start and rematch are host-controlled; the online UI drops
the pass/reveal screens and waits on the opponent instead. The Game instance
exists only on the host.

Godot RPCs are addressed by scene-tree path, so the Server node must sit at
the same path on every machine: main.gd always creates the session as
"OnlineSession" under the main scene, and the tests build the identical
tree by hand.

## Checks

From the project directory, using your Godot executable:

    godot --headless --path . -s res://test_game.gd
    godot --headless --path . -s res://test_ui.gd
    godot --headless --path . -s res://test_net.gd
    TRUC_ROLE=host  godot --headless --path . -s res://test_net.gd
    TRUC_ROLE=guest godot --headless --path . -s res://test_net.gd

The original components/card.tscn references res://card.gd, which does not exist.
The new UI does not use that scene. The card-design teammate should update that
reference to res://components/card.gd if reusing it.

The shared sage/forest/cream theme and learning pages are in ui/main.gd. Online Play joins two players over the local network with hidden hands.

