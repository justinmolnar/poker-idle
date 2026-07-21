// shaders/dirty.frag
//
// Makes the card back art look dirty/sepia/desaturated. Used for Level 0 decks.

vec4 effect(vec4 color, Image texture, vec2 texture_coords, vec2 screen_coords) {
    vec4 tex = Texel(texture, texture_coords);
    
    // Grayscale conversion
    float gray = dot(tex.rgb, vec3(0.299, 0.587, 0.114));
    
    // Sepia-ish dirty tinting: warm dark browns and muted highlights
    vec3 dirty = vec3(gray) * vec3(0.60, 0.50, 0.40);
    
    // Mute the alpha slightly to make it feel dusty/faded
    return vec4(dirty * color.rgb, tex.a * color.a * 0.85);
}
