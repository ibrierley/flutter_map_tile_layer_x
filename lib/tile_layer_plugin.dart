library tile_layer_plugin;

import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/widgets.dart';
import 'package:latlong/latlong.dart';
import 'package:transparent_image/transparent_image.dart';
import 'package:tuple/tuple.dart';
import 'package:flutter_map/plugin_api.dart';

/// Describes the needed properties to create a tile-based layer.
/// A tile is an image binded to a specific geographical position.
class TileLayerPluginOptions extends TileLayerOptions {
  /// Defines the structure to create the URLs for the tiles.
  ///
  /// Example:
  ///
  /// https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png
  ///
  /// Is translated to this:
  ///
  /// https://a.tile.openstreetmap.org/12/2177/1259.png
  final String urlTemplate;

  /// If `true`, inverses Y axis numbering for tiles (turn this on for
  /// [TMS](https://en.wikipedia.org/wiki/Tile_Map_Service) services).
  final bool tms;

  /// If not `null`, then tiles will pull's WMS protocol requests
  final WMSTileLayerOptions wmsOptions;

  /// Size for the tile.
  /// Default is 256
  final double tileSize;

  /// The max zoom applicable. In most tile providers goes from 0 to 19.
  final double maxZoom;

  final bool zoomReverse;
  final double zoomOffset;

  /// List of subdomains for the URL.
  ///
  /// Example:
  ///
  /// Subdomains = {a,b,c}
  ///
  /// and the URL is as follows:
  ///
  /// https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png
  ///
  /// then:
  ///
  /// https://a.tile.openstreetmap.org/{z}/{x}/{y}.png
  /// https://b.tile.openstreetmap.org/{z}/{x}/{y}.png
  /// https://c.tile.openstreetmap.org/{z}/{x}/{y}.png
  final List<String> subdomains;

  ///Color shown behind the tiles.
  final Color backgroundColor;

  ///Opacity of the rendered tile
  final double opacity;

  /// Provider to load the tiles. The default is CachedNetworkTileProvider,
  /// which loads tile images from network and caches them offline.
  ///
  /// If you don't want to cache the tiles, use NetworkTileProvider instead.
  ///
  /// In order to use images from the asset folder set this option to
  /// AssetTileProvider() Note that it requires the urlTemplate to target
  /// assets, for example:
  ///
  /// ```dart
  /// urlTemplate: "assets/map/anholt_osmbright/{z}/{x}/{y}.png",
  /// ```
  ///
  /// In order to use images from the filesystem set this option to
  /// FileTileProvider() Note that it requires the urlTemplate to target the
  /// file system, for example:
  ///
  /// ```dart
  /// urlTemplate: "/storage/emulated/0/tiles/some_place/{z}/{x}/{y}.png",
  /// ```
  ///
  /// Furthermore you create your custom implementation by subclassing
  /// TileProvider
  ///
  final TileProvider tileProvider;

  /// Deprecated, as we try and work on a system having some sort of
  /// caching anyway now.
  /// When panning the map, keep this many rows and columns of tiles before
  /// unloading them.
  /// final int keepBuffer;

  /// Placeholder to show until tile images are fetched by the provider.
  ImageProvider placeholderImage;

  /// Static informations that should replace placeholders in the [urlTemplate].
  /// Applying API keys is a good example on how to use this parameter.
  ///
  /// Example:
  ///
  /// ```dart
  ///
  /// TileLayerOptions(
  ///     urlTemplate: "https://api.tiles.mapbox.com/v4/"
  ///                  "{id}/{z}/{x}/{y}@2x.png?access_token={accessToken}",
  ///     additionalOptions: {
  ///         'accessToken': '<PUT_ACCESS_TOKEN_HERE>',
  ///          'id': 'mapbox.streets',
  ///     },
  /// ),
  /// ```
  ///
  Map<String, String> additionalOptions;

  /// Try and grab tiles in advance for pan direction. 1 probably a good balance.
  /// Don't set this much higher than one, or there may be too many tile requests.
  /// 0 May be better if network limited for example.
  int greedyTileCount;

  /// A List of relative zoom in/out order that we try. Example [1,2,3,-1,-2]
  /// Try 3 levels of old larger tiles, then 2 levels of old smaller ones
  List backupTileExpansionStrategy;

  TileLayerPluginOptions(
      {this.urlTemplate,
        this.tileSize = 256.0,
        this.maxZoom = 18.0,
        this.zoomReverse = false,
        this.zoomOffset = 0.0,
        this.additionalOptions = const <String, String>{},
        this.subdomains = const <String>[],
        ///this.keepBuffer = 2, /// deprecated, see above
        this.backgroundColor = const Color(0xFFE0E0E0),
        this.placeholderImage,
        this.tileProvider = const CachedNetworkTileProvider(),
        this.tms = false,
        // ignore: avoid_init_to_null
        this.wmsOptions = null,
        this.opacity = 1.0,
        this.greedyTileCount = 1,
        this.backupTileExpansionStrategy = const [1, 2, 3, -1, -2],
        rebuild})
      : super(rebuild: rebuild);
}

class TileLayerPlugin implements MapPlugin {
  @override
  Widget createLayer(
      LayerOptions options, MapState mapState, Stream<Null> stream) {

    if (options is TileLayerPluginOptions) {
      return TileLayerX(options, mapState, stream);
    }
    throw Exception('Unknown options type for TileLayerXPlugin: $options');
  }

  @override
  bool supportsLayer(LayerOptions options) {
    return options is TileLayerPluginOptions;
  }
}

class TileLayerX extends StatefulWidget {
  final TileLayerPluginOptions tileLayerOptions;
  final MapState mapState;
  final Stream<Null> stream;

  TileLayerX(
      this.tileLayerOptions,
      this.mapState,
      this.stream,
      );

  @override
  State<StatefulWidget> createState() {
    return _TileLayerState();
  }
}

class _TileLayerState extends State<TileLayerX> {
  MapState get map => widget.mapState;
  TileLayerPluginOptions get options => widget.tileLayerOptions;
  Bounds _globalTileRange;
  Tuple2<double, double> _wrapX;
  Tuple2<double, double> _wrapY;
  double _tileZoom;
  Level _level;
  StreamSubscription _moveSub;

  final Map<double, Level> _levels = {};

  final Map<String, DateTime> _outstandingTileLoads = {};
  final Map<String, DateTime> _recentTilesCompleted = {};

  int _secondsBetweenListCleanups = 20;
  DateTime _lastTileListCleanupTime = DateTime.now();

  LatLng _prevCenter;
  Timer _housekeepingTimer;

  @override
  void initState() {
    super.initState();
    _resetView();
    _moveSub = widget.stream.listen((_) => _handleMove());
    _housekeepingTimer = Timer.periodic(Duration(hours: 24), (Timer t) => _tidyOldTileListEntries());
  }

  @override
  void dispose() {
    super.dispose();
    _moveSub?.cancel();
    _housekeepingTimer.cancel();
    options.tileProvider.dispose();
  }
  void _handleMove() {
    setState(() {
      /// Not needed now, as we don't leave tiles hanging about, we just
      /// try and do the right thing and display, with a strategy to try
      /// recently loaded tiles if a current tile is outstanding.
      /// _pruneTiles();
      _resetView();
    });
  }

  void _resetView() {
    _setView(map.center, map.zoom);
  }

  void _setView(LatLng center, double zoom) {
    var tileZoom = _clampZoom(zoom.round().toDouble());
    if (_tileZoom != tileZoom) {
      _tileZoom = tileZoom;
      _updateLevels();
      _resetGrid();
    }
    _setZoomTransforms(center, zoom);
  }

  Level _updateLevels() {
    var zoom = _tileZoom;
    var maxZoom = options.maxZoom;

    if (zoom == null) return null;

    for (var z in _levels.keys) {
      if (_levels[z].children.isNotEmpty || z == zoom) {
        _levels[z].zIndex = maxZoom = (zoom - z).abs();
      }
    }

    var level = _levels[zoom];
    var map = this.map;

    if (level == null) {
      level = _levels[zoom] = Level();
      level.zIndex = options.maxZoom;
      var newOrigin = map.project(map.unproject(map.getPixelOrigin()), zoom);
      if (newOrigin != null) {
        level.origin = newOrigin;
      } else {
        level.origin = CustomPoint(0.0, 0.0);
      }
      level.zoom = zoom;

      _setZoomTransform(level, map.center, map.zoom);
    }
    _level = level;
    return level;
  }

  void _setZoomTransform(Level level, LatLng center, double zoom) {
    var scale = map.getZoomScale(zoom, level.zoom);
    var pixelOrigin = map.getNewPixelOrigin(center, zoom).round();
    if (level.origin == null) {
      return;
    }
    var translate = level.origin.multiplyBy(scale) - pixelOrigin;
    level.translatePoint = translate;
    level.scale = scale;
  }

  void _setZoomTransforms(LatLng center, double zoom) {
    for (var i in _levels.keys) {
      _setZoomTransform(_levels[i], center, zoom);
    }
  }

  void _resetGrid() {
    var map = this.map;
    var crs = map.options.crs;
    var tileSize = getTileSize();
    var tileZoom = _tileZoom;

    var bounds = map.getPixelWorldBounds(_tileZoom);
    if (bounds != null) {
      _globalTileRange = _pxBoundsToTileRange(bounds);
    }

    // wrapping
    _wrapX = crs.wrapLng;
    if (_wrapX != null) {
      var first =
      (map.project(LatLng(0.0, crs.wrapLng.item1), tileZoom).x / tileSize.x)
          .floor()
          .toDouble();
      var second =
      (map.project(LatLng(0.0, crs.wrapLng.item2), tileZoom).x / tileSize.y)
          .ceil()
          .toDouble();
      _wrapX = Tuple2(first, second);
    }

    _wrapY = crs.wrapLat;
    if (_wrapY != null) {
      var first =
      (map.project(LatLng(crs.wrapLat.item1, 0.0), tileZoom).y / tileSize.x)
          .floor()
          .toDouble();
      var second =
      (map.project(LatLng(crs.wrapLat.item2, 0.0), tileZoom).y / tileSize.y)
          .ceil()
          .toDouble();
      _wrapY = Tuple2(first, second);
    }
  }

  double _clampZoom(double zoom) {
    // todo
    return zoom;
  }

  CustomPoint getTileSize() {
    return CustomPoint(options.tileSize, options.tileSize);
  }

  @override
  Widget build(BuildContext context) {
    var pixelBounds = _getTiledPixelBounds(map.center);
    var tileRange = _pxBoundsToTileRange(pixelBounds);
    var tileCenter = tileRange.getCenter();
    var queue = <Coords>[];
    var _backupTiles = {};
    var _tiles = {};

    /// Just a little bit of housekeeping we don't need to run too much
    /// to keep an eye on old tiles in a completed tile check
    if (DateTime.now().difference(_lastTileListCleanupTime) >
        Duration(seconds: _secondsBetweenListCleanups)) {
      _lastTileListCleanupTime = DateTime.now();
    }

    _setView(map.center, map.zoom);

    int miny = tileRange.min.y;
    int maxy = tileRange.max.y;
    int minx = tileRange.min.x;
    int maxx = tileRange.max.x;

    /// We try and preload some tiles if option set, so with panning there isn't such
    /// a delay in loading the next tile.
    _prevCenter ??= map.center;

    if (map.center.latitude < _prevCenter.latitude) {
      maxy += options.greedyTileCount; //Up
    }
    if (map.center.latitude > _prevCenter.latitude) {
      miny -= options.greedyTileCount; //Down
    }
    if (map.center.longitude > _prevCenter.longitude) {
      maxx += options.greedyTileCount; //Left
    }
    if (map.center.longitude < _prevCenter.longitude) {
      minx -= options.greedyTileCount; //Right
    }

    for (var j = miny; j <= maxy; j++) {
      for (var i = minx; i <= maxx; i++) {
        var coords = Coords(i.toDouble(), j.toDouble());
        coords.z = _tileZoom;

        if (!_isValidTile(coords)) {
          continue;
        }

        // Add all valid tiles to the queue on Flutter
        queue.add(coords);

        /// If a tile is outstanding still, or has never been loaded recently
        /// We'll try and look for other tiles on levels above/below, depending
        /// on our expansion strategy. Example of backupTileExpansionStrategy
        /// would be [1,2,3,-1] which means if we are zoom 14, we'll check 13,
        /// then 12, 11, then 15.
        if (_outstandingTileLoads.containsKey(_tileCoordsToKey(coords)) ||
            !_recentTilesCompleted.containsKey(_tileCoordsToKey(coords))) {
          Coords backupCoords;

          /// If we've found backuptiles, we don't want to pursue any more
          var haveBackup = false;

          /// This works by expanding on a power of 2, eg tile 32,11 covers
          /// 64,22 & 65,22 & 64,23 & 65, 23 in one direction, and 16,10 in going
          /// backwards. So if we've recently completed it, there's a good chance
          /// it's a the cache.

          options.backupTileExpansionStrategy.forEach((levelDifference) {
            var ratio = pow(2, levelDifference);

            /// If we need covering tiles from a higher zoom we may need
            /// several tiles to cover each 'larger' tile, extraTileFactor.
            if (!haveBackup) {
              var extraTileFactor = (1 / ratio).abs();

              for (var a = 0; a < extraTileFactor; a++) {
                for (var b = 0; b < extraTileFactor; b++) {
                  var backupZoom = _tileZoom - levelDifference;
                  if (backupZoom > options.maxZoom || backupZoom < 0) continue;

                  backupCoords = Coords(
                      (i ~/ ratio + a).toDouble(), (j ~/ ratio + b).toDouble());
                  backupCoords.z = backupZoom;

                  var tileKey = _tileCoordsToKey(backupCoords);

                  /// It shouldn't end up both completed && outstanding, but it
                  /// could be possible if was in cache but not any more...
                  if (_recentTilesCompleted.containsKey(tileKey) &&
                      !_outstandingTileLoads.containsKey(tileKey)) {
                    _backupTiles[tileKey] = Tile(backupCoords, false);
                    haveBackup = true;
                  }
                }
              }
            }
          });
        }
      }
    }

    if (queue.isNotEmpty) {
      for (var i = 0; i < queue.length; i++) {
        _tiles[_tileCoordsToKey(queue[i])] = Tile(_wrapCoords(queue[i]), true);
      }
    }

    var tilesToRender = <Tile>[
      for (var tile in _tiles.values)
        if ((tile.coords.z - _level.zoom).abs() <= 1) tile
    ];

    tilesToRender.sort((aTile, bTile) {
      final a = aTile.coords; // TODO there was an implicit casting here.
      final b = bTile.coords;
      // a = 13, b = 12, b is less than a, the result should be positive.
      if (a.z != b.z) {
        return (b.z - a.z).toInt();
      }
      return (a.distanceTo(tileCenter) - b.distanceTo(tileCenter)).toInt();
    });

    var backupTilesToRender = <Tile>[
      for (var tile in _backupTiles.values) tile
    ];

    var allTilesToRender = backupTilesToRender + tilesToRender;

    var tileWidgets = <Widget>[
      for (var tile in allTilesToRender) _createTileWidget(tile.coords)
    ];

    return Opacity(
      opacity: options.opacity,
      child: Container(
        color: options.backgroundColor,
        child: Stack(
          children: tileWidgets,
        ),
      ),
    );
  }

  Bounds _getTiledPixelBounds(LatLng center) {
    return getPixelBoundsFixed(map,_tileZoom);
  }

  Bounds _pxBoundsToTileRange(Bounds bounds) {
    var tileSize = getTileSize();
    return Bounds(
      bounds.min.unscaleBy(tileSize).floor(),
      bounds.max.unscaleBy(tileSize).ceil() - CustomPoint(1, 1),
    );
  }

  bool _isValidTile(Coords coords) {
    var crs = map.options.crs;
    if (!crs.infinite) {
      var bounds = _globalTileRange;
      if ((crs.wrapLng == null &&
          (coords.x < bounds.min.x || coords.x > bounds.max.x)) ||
          (crs.wrapLat == null &&
              (coords.y < bounds.min.y || coords.y > bounds.max.y))) {
        return false;
      }
    }
    return true;
  }

  String _tileCoordsToKey(Coords coords) {
    return '${coords.x}:${coords.y}:${coords.z}';
  }

  Widget _createTileWidget(Coords coords) {
    var tilePos = _getTilePos(coords);
    var level = _levels[coords.z];
    var tileSize = getTileSize();
    var pos = (tilePos).multiplyBy(level.scale) + level.translatePoint;
    var width = tileSize.x * level.scale;
    var height = tileSize.y * level.scale;

    final Widget content = Container(
      child: FadeInImage(
        fadeInDuration: const Duration(milliseconds: 100),
        key: Key(_tileCoordsToKey(coords)),
        placeholder: options.placeholderImage != null
            ? options.placeholderImage
            : MemoryImage(kTransparentImage),
        image: _imageProviderFinishedCheck(coords, options),
        fit: BoxFit.fill,
      ),
    );

    return Positioned(
        left: pos.x.toDouble(),
        top: pos.y.toDouble(),
        width: width.toDouble(),
        height: height.toDouble(),
        child: content);
  }

  /// An image callback, so that we can do something when a tile has finished
  /// loading. Used to try and help keep older tiles until it's finished loading.
  ImageProvider _imageProviderFinishedCheck(coords, options) {
    var coordsKey = _tileCoordsToKey(coords);
    ImageProvider newImageProvider =
    options.tileProvider.getImage(coords, options);

    if (!_recentTilesCompleted.containsKey(coordsKey))
      _outstandingTileLoads[coordsKey] = DateTime.now();

    newImageProvider.resolve(ImageConfiguration()).addListener(
      ImageStreamListener((info, call) {
        _recentTilesCompleted[coordsKey] = DateTime.now();
        _outstandingTileLoads.remove(coordsKey);
      }, onError: ((e, trace) {
        print('Image not loaded, error: $e');
      })),
    );
    return newImageProvider;
  }

  void _tidyOldTileListEntries() {
    print("TIDYING!!!!!");
    /// We don't want to consider a tile outstanding forever, but it may vary
    /// We could tie it into some tileretry/timeout setting somewhere, but that
    /// may be quite tricky, so currently we'll suggest 1 day. It will get removed
    /// if the tile is tried another time and completed.
    _outstandingTileLoads.removeWhere((key, timeCompleted) =>
    DateTime.now().difference(timeCompleted).inMinutes >= 1440);

    /// We only want to try and use our retries within a reasonable session
    /// So we'll assume people will be fine with a reset of our retries every
    /// day
    _recentTilesCompleted.removeWhere((key, timeCompleted) =>
    DateTime.now().difference(timeCompleted).inMinutes >= 1440);
  }

  Coords _wrapCoords(Coords coords) {
    var newCoords = Coords(
      _wrapX != null
          ? wrapNum(coords.x.toDouble(), _wrapX)
          : coords.x.toDouble(),
      _wrapY != null
          ? wrapNum(coords.y.toDouble(), _wrapY)
          : coords.y.toDouble(),
    );
    newCoords.z = coords.z.toDouble();
    return newCoords;
  }

  CustomPoint _getTilePos(Coords coords) {
    var level = _levels[coords.z];
    return coords.scaleBy(getTileSize()) - level.origin;
  }

  double wrapNum(double x, Tuple2<double, double> range, [bool includeMax]) {
    var max = range.item2;
    var min = range.item1;
    var d = max - min;
    return x == max && includeMax != null ? x : ((x - min) % d + d) % d + min;
  }

  Bounds getPixelBoundsFixed(MapState map, double zoom) {
    var mapZoom = map.zoom;
    var scale = map.getZoomScale(mapZoom, zoom);
    var pixelCenter = map.project(map.center, zoom).floor();
    var halfSize = map.size / (scale * 2);
    return Bounds(pixelCenter - halfSize, pixelCenter + halfSize);
  }

}
