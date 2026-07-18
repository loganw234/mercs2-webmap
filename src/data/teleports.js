// Teleport spots -- named locations you can jump to in-game. Click a dot -> "Teleport here" runs
// Ess.Player.teleport(x,y,z,yaw) over the live bridge (needs a connection). This layer grows as users
// collect spots with the in-game [Ess][LOCATION] tool; seeded here with the first spot.
//
// Shape: same generic dataset as any other layer, plus kind:"teleport" and per-point `name` + `yaw`.
window.MERCS_TELEPORTS = {
  id: "teleports",
  name: "Teleport spots",
  kind: "teleport",
  color: "#3fd0e0",
  points: [
    { name: "Runway", position: { x: 2708.85, y: -13.97, z: -642.95 }, yaw: 165.7 }
  ]
};
