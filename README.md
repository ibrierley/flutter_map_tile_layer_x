# flutter_map_tile_layer_x

Tile Layer Plugin for flutter_map

This fixes various tile loading issues and the odd bug. It's waiting on a pull request to swap the order of plugins around though, so you can override default layers.

Add
```
                plugins: [
                  TileLayerPlugin(),
                ],

```

To your map options, and then add

```
TileLayerPluginOptions(
                        urlTemplate:
                        'https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png',
                        subdomains: ['a', 'b', 'c']),
                      )
```

To your layers, instead of the usual TileLayerOptions.
