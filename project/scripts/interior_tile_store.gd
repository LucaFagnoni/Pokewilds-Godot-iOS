class_name InteriorTileStore
extends WorldTileStore
## One interior plan's tiles (SourceInteriorGenerator), packed as the
## overworld's are: a SourceTile object costs about 2.5 KB and the interiors
## hold about 10,000 tiles. An interior is a few rooms spread over a wide
## plane, so its cells are a list in the plan's order rather than a mostly
## empty rectangle. Keys are the plan's local cells and iterate in that
## order; a tile's position stays its source pixel position. Tiles change
## through their proxies only (no put or erase).

## The local cell at each index, in the plan's order.
var cells: Array[Vector2i] = []
var _positions: Array[Vector2i] = []
var _indices := {}

## Packs a plan's tiles, keyed by local cell.
static func pack(tiles: Dictionary) -> InteriorTileStore:
    var store := InteriorTileStore.new()
    # The arrays are laid out as a strip of cells, one per index.
    store._cover(Rect2i(0, 0, tiles.size(), 1))
    for local in tiles:
        var tile := tiles[local] as SourceTile
        var index := store.cells.size()
        store.cells.append(local)
        store._positions.append(tile.position)
        store._indices[local] = index
        store._write(Vector2i(index * TILE, 0), tile)
    store._keys = store.cells
    store._keys_valid = true
    return store

func index_of(key: Vector2i) -> int:
    return _indices.get(key, -1)

## The tile's source pixel position, which its proxy reads as `position`.
func key_of(index: int) -> Vector2i:
    return _positions[index]
