#version 450
layout(set = 0, binding = 0) uniform sampler2D tex;
layout(push_constant) uniform PC { vec2 size; } pc;
layout(location = 0) out vec4 o;
void main() { o = texture(tex, gl_FragCoord.xy / pc.size); }
