fx_version 'cerulean'
game 'gta5'

name        'bonez-bodycam_evidence'
description 'Court Evidence Recording & Playback — addon for bonez-bodycam'
version     '1.0.0'
author      'Bonez Workshop'

dependency  'bonez-bodycam'
dependency  'night_ers'

optional_dependency 'oxmysql'

shared_scripts {
    'config.lua',
    'shared/util.lua',
}

client_scripts {
    'client/recorder.lua',
    'client/viewer.lua',
    'client/main.lua',
}

server_scripts {
    'server/apiKeys.lua',   -- API keys — server-side only, never touches clients
    'server/upload.lua',    -- Upload adapters (Fivemanage / LBUpload / Custom)
    'server/storage.lua',
    'server/video.lua',
    'server/main.lua',
}

ui_page 'html/index.html'

-- Allow the NUI page to fetch() to Fivemanage's upload endpoints.
-- FiveM blocks external fetch calls from NUI by default; without this
-- the presigned-URL upload fails with "Failed to fetch".
nui_allow_urls {
    'https://*.fivemanage.com/*',
    'https://api.fivemanage.com/*',
}

files {
    'html/index.html',
    'html/style.css',
    'html/script.js',
    'html/cfx_renderer.js',

    -- Three.js module — each subdirectory must be listed explicitly;
    -- FiveM does not support deep ** globs for NUI file serving.
    'module/*.js',
    'module/animation/*.js',
    'module/animation/tracks/*.js',
    'module/audio/*.js',
    'module/cameras/*.js',
    'module/core/*.js',
    'module/extras/*.js',
    'module/extras/core/*.js',
    'module/extras/curves/*.js',
    'module/extras/objects/*.js',
    'module/geometries/*.js',
    'module/helpers/*.js',
    'module/lights/*.js',
    'module/loaders/*.js',
    'module/materials/*.js',
    'module/math/*.js',
    'module/math/interpolants/*.js',
    'module/objects/*.js',
    'module/renderers/*.js',
    'module/renderers/shaders/*.js',
    'module/renderers/shaders/ShaderChunk/*.js',
    'module/renderers/shaders/ShaderLib/*.js',
    'module/renderers/webgl/*.js',
    'module/renderers/webvr/*.js',
    'module/scenes/*.js',
    'module/textures/*.js',
}
