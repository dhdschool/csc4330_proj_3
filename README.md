# Playing Le Truc

Open project.godot in Godot 4.7 and press F5 (Run Project).
Choose Local Play. Two players share the computer, passing it at each player change.
The incoming player selects Reveal my hand. Choose a card during the play phase;
use the other buttons to keep/request a deal, negotiate stakes, or concede.
The match ends at 12 points and offers Play again. Online Play currently opens a
Coming soon screen; no connections are made.

The original rules in components/game.gd are unchanged.

## Team handoff

- ui/main.tscn is the configured main scene.
- ui/main.gd builds the interface. Placeholder cards are created in the hand loop
  in _refresh(); replace those Buttons with the team's card scene while keeping
  the callback _act("play_card", hand_index). Rank and suit are numeric enum values
  matching components/card_data.gd; label is a fallback description.
- ui/local_session.gd owns the rules instance and exposes plain-data snapshots and
  validated commands. changed tells the interface to refresh after rules advance.
- test_ui.gd drives complete matches through the UI action path and checks stale
  commands, wrong-seat commands, spectator hand privacy, and match restarts.

## Networking integration (not implemented)

Run the Game instance only on the host. Send an action name, hand index (or -1),
and the snapshot revision to the host. Derive the requesting seat from the peer's
assigned identity; never trust a client-supplied seat. Invoke submit on the host.
Send snapshot_for(1) only to player 1 and snapshot_for(2) only to player 2. Never
broadcast the rules object, deck, or both snapshots. History contains only public
plays and actions. The local mode hides hands for convenience, not security.

The online client should render its assigned seat's snapshot even while waiting
for the opponent. Replace local _refresh's session.seat lookup with that fixed seat,
remove pass/reveal screens for online mode, and forward _deliver commands through
the transport. The data contract is intentionally reusable, but the online adapter,
host/join interface, peer identity, disconnections, and synchronization still need
implementation. Start/restart must be host-controlled, with a fresh snapshot sent
to both peers. Revision numbers reject stale or duplicate actions within a session.

## Checks

From the project directory, using your Godot executable:

	godot --headless --path . -s res://test_game.gd
	godot --headless --path . -s res://test_ui.gd

The original components/card.tscn references res://card.gd, which does not exist.
The new UI does not use that scene. The card-design teammate should update that
reference to res://components/card.gd if reusing it.

## Learning pages and theme
The main menu includes Game Rules and Tutorial. Tutorial is a scripted, interactive teaching round (not a live opponent), with retry feedback and no effect on match scores. The shared sage/forest/cream theme and learning pages are in ui/main.gd. Online Play remains a placeholder.
