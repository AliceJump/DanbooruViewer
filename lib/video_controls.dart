import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

class DanbooruVideoPlayer extends StatefulWidget {
  final VideoPlayerController controller;
  final bool compact;
  final VoidCallback? onOpenFullScreen;

  const DanbooruVideoPlayer({
    super.key,
    required this.controller,
    this.compact = false,
    this.onOpenFullScreen,
  });

  @override
  State<DanbooruVideoPlayer> createState() => _DanbooruVideoPlayerState();
}

class _DanbooruVideoPlayerState extends State<DanbooruVideoPlayer> {
  static const List<double> _speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

  double _speed = 1.0;
  bool _isSeeking = false;
  double? _dragPositionMs;

  VideoPlayerController get _controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_handleControllerChanged);
  }

  @override
  void didUpdateWidget(DanbooruVideoPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_handleControllerChanged);
      _speed = 1.0;
      _isSeeking = false;
      _dragPositionMs = null;
      _controller.addListener(_handleControllerChanged);
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_handleControllerChanged);
    super.dispose();
  }

  void _handleControllerChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _togglePlay() async {
    try {
      if (_controller.value.isPlaying) {
        await _controller.pause();
      } else {
        await _controller.play();
      }
    } on Object {
      _showPlaybackError();
    }
  }

  void _showPlaybackError() {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('系统无法播放此媒体，请重试或保存后使用外部播放器。')));
  }

  Future<void> _setSpeed(double speed) async {
    try {
      await _controller.setPlaybackSpeed(speed);
    } on Object {
      _showPlaybackError();
      return;
    }
    if (!mounted) return;
    setState(() {
      _speed = speed;
    });
  }

  String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');

    if (hours > 0) {
      return '$hours:$minutes:$seconds';
    }
    return '$minutes:$seconds';
  }

  Widget _buildSpeedButton() {
    return PopupMenuButton<double>(
      tooltip: '播放速度',
      initialValue: _speed,
      onSelected: _setSpeed,
      itemBuilder: (context) {
        return _speeds
            .map(
              (speed) =>
                  PopupMenuItem<double>(value: speed, child: Text('${speed}x')),
            )
            .toList();
      },
      child: SizedBox(
        width: 56,
        height: 48,
        child: Center(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              '${_speed}x',
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildControls() {
    final value = _controller.value;
    final duration = value.duration;
    final position = _isSeeking && _dragPositionMs != null
        ? Duration(milliseconds: _dragPositionMs!.round())
        : value.position;
    final maxMs = duration.inMilliseconds <= 0
        ? 1.0
        : duration.inMilliseconds.toDouble();
    final currentMs = position.inMilliseconds
        .clamp(0, maxMs.toInt())
        .toDouble();

    return Container(
      padding: EdgeInsets.fromLTRB(
        8,
        widget.compact ? 4 : 8,
        8,
        widget.compact ? 4 : 10,
      ),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.transparent, Colors.black.withValues(alpha: 0.72)],
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              IconButton(
                tooltip: value.isPlaying ? '暂停' : '播放',
                color: Colors.white,
                icon: Icon(value.isPlaying ? Icons.pause : Icons.play_arrow),
                onPressed: _togglePlay,
              ),
              Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '${_formatDuration(position)} / ${_formatDuration(duration)}',
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ),
              ),
              _buildSpeedButton(),
              if (widget.onOpenFullScreen != null)
                IconButton(
                  tooltip: '全屏',
                  color: Colors.white,
                  icon: const Icon(Icons.fullscreen),
                  onPressed: widget.onOpenFullScreen,
                ),
            ],
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
            ),
            child: Slider(
              min: 0,
              max: maxMs,
              value: currentMs,
              onChangeStart: (value) {
                setState(() {
                  _isSeeking = true;
                  _dragPositionMs = value;
                });
              },
              onChanged: (value) {
                setState(() {
                  _dragPositionMs = value;
                });
              },
              onChangeEnd: (value) async {
                try {
                  await _controller.seekTo(
                    Duration(milliseconds: value.round()),
                  );
                } on Object {
                  _showPlaybackError();
                }
                if (!mounted) return;
                setState(() {
                  _isSeeking = false;
                  _dragPositionMs = null;
                });
              },
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final aspectRatio = _controller.value.aspectRatio == 0
        ? 1.0
        : _controller.value.aspectRatio;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _togglePlay,
      child: Stack(
        alignment: Alignment.center,
        children: [
          AspectRatio(
            aspectRatio: aspectRatio,
            child: VideoPlayer(_controller),
          ),
          if (!_controller.value.isPlaying)
            Icon(
              Icons.play_circle_outline,
              size: widget.compact ? 60 : 80,
              color: Colors.white.withValues(alpha: 0.72),
            ),
          Positioned(left: 0, right: 0, bottom: 0, child: _buildControls()),
        ],
      ),
    );
  }
}
