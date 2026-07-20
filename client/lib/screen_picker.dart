import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

class ScreenPickerWidget extends StatefulWidget {
  final Function(String sourceId, int fps, int resolution) onSourceSelected;

  const ScreenPickerWidget({Key? key, required this.onSourceSelected}) : super(key: key);

  @override
  _ScreenPickerWidgetState createState() => _ScreenPickerWidgetState();
}

class _ScreenPickerWidgetState extends State<ScreenPickerWidget> {
  List<DesktopCapturerSource> _sources = [];
  bool _isLoading = true;
  int _selectedFps = 30;
  int _selectedResolution = 720;
  
  final List<int> _fpsOptions = [30, 60];
  final Map<int, String> _resolutionOptions = {
    480: '480p (SD)',
    720: '720p (HD)',
    1080: '1080p (FHD)'
  };

  @override
  void initState() {
    super.initState();
    _loadSources();
  }

  Future<void> _loadSources() async {
    setState(() => _isLoading = true);
    try {
      final sources = await desktopCapturer.getSources(types: [
        SourceType.Window,
        SourceType.Screen,
      ]);
      setState(() {
        _sources = sources;
        _isLoading = false;
      });
    } catch (e) {
      debugPrint('Error getting sources: $e');
      setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      width: 800,
      height: 600,
      decoration: BoxDecoration(
        color: const Color(0xFF161426),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Share your screen',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white),
              ),
              IconButton(
                icon: const Icon(Icons.refresh, color: Colors.white70),
                onPressed: _loadSources,
                tooltip: 'Refresh windows',
              )
            ],
          ),
          const SizedBox(height: 16),
          // Quality controls
          Row(
            children: [
              const Text('Resolution:', style: TextStyle(color: Colors.white70)),
              const SizedBox(width: 8),
              DropdownButton<int>(
                value: _selectedResolution,
                dropdownColor: const Color(0xFF262436),
                style: const TextStyle(color: Colors.white),
                items: _resolutionOptions.entries.map((e) => DropdownMenuItem(
                  value: e.key,
                  child: Text(e.value),
                )).toList(),
                onChanged: (val) {
                  if (val != null) setState(() => _selectedResolution = val);
                },
              ),
              const SizedBox(width: 24),
              const Text('FPS:', style: TextStyle(color: Colors.white70)),
              const SizedBox(width: 8),
              DropdownButton<int>(
                value: _selectedFps,
                dropdownColor: const Color(0xFF262436),
                style: const TextStyle(color: Colors.white),
                items: _fpsOptions.map((fps) => DropdownMenuItem(
                  value: fps,
                  child: Text('$fps FPS'),
                )).toList(),
                onChanged: (val) {
                  if (val != null) setState(() => _selectedFps = val);
                },
              ),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(
            child: _isLoading 
              ? const Center(child: CircularProgressIndicator())
              : _sources.isEmpty
                ? const Center(child: Text('No windows found.', style: TextStyle(color: Colors.white70)))
                : GridView.builder(
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 3,
                      crossAxisSpacing: 16,
                      mainAxisSpacing: 16,
                      childAspectRatio: 1.2,
                    ),
                    itemCount: _sources.length,
                    itemBuilder: (context, index) {
                      final source = _sources[index];
                      return InkWell(
                        onTap: () {
                          widget.onSourceSelected(source.id, _selectedFps, _selectedResolution);
                        },
                        child: Container(
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.05),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Colors.white.withOpacity(0.1)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Expanded(
                                child: ClipRRect(
                                  borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
                                  child: source.thumbnail != null && source.thumbnail!.isNotEmpty
                                      ? Image.memory(source.thumbnail!, fit: BoxFit.contain)
                                      : const Icon(Icons.desktop_windows, size: 48, color: Colors.white38),
                                ),
                              ),
                              Container(
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  color: Colors.black.withOpacity(0.5),
                                  borderRadius: const BorderRadius.vertical(bottom: Radius.circular(8)),
                                ),
                                child: Text(
                                  source.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(color: Colors.white, fontSize: 12),
                                  textAlign: TextAlign.center,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
