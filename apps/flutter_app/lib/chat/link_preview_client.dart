import 'package:http/http.dart' as http;

import 'link_preview_client_web.dart'
    if (dart.library.io) 'link_preview_client_native.dart'
    as platform;

http.Client createLinkPreviewClient() => platform.createLinkPreviewClient();
