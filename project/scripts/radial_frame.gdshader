shader_type canvas_item;
render_mode unshaded;
uniform float base_radius = 76.0;
uniform float border_outset = 1.0;
vec4 border_pixel(sampler2D artwork, vec2 dimensions, float column, float row) {
    float sx=8.0+mod(column,max(1.0,dimensions.x-16.0));
    float sy=clamp(row,0.0,min(7.0,dimensions.y-1.0));
    vec4 ink=texture(artwork,(vec2(sx,sy)+vec2(0.5))/dimensions);
    return ink.a<0.5 ? vec4(1.0) : ink;
}
void fragment() {
    vec2 offset=(UV-vec2(0.5))*2.0*(base_radius+border_outset);
    float radius=(length(offset)-border_outset)*64.0/base_radius;
    float edge=max(fwidth(radius),0.001);
    float coverage=smoothstep(53.0-edge*0.5,53.0+edge*0.5,radius)*(1.0-smoothstep(63.0-edge*0.5,63.0+edge*0.5,radius));
    vec2 dimensions=vec2(textureSize(TEXTURE,0));
    float angle=mod(atan(offset.y,offset.x)+1.57079632679+6.28318530718,6.28318530718);
    float column=angle*30.0;
    float row=(63.0-radius)*0.7;
    // Blend across the nearest texel boundary using the display pixel footprint.
    float rb=floor(row+0.5);
    float cb=floor(column+0.5);
    float rw=max(fwidth(row),0.001)*0.5;
    float cw=max(30.0*edge/max(radius,1.0),0.001)*0.5;
    float ry=smoothstep(rb-rw,rb+rw,row);
    float cx=smoothstep(cb-cw,cb+cw,column);
    vec4 low=mix(border_pixel(TEXTURE,dimensions,cb-1.0,rb-1.0),border_pixel(TEXTURE,dimensions,cb,rb-1.0),cx);
    vec4 high=mix(border_pixel(TEXTURE,dimensions,cb-1.0,rb),border_pixel(TEXTURE,dimensions,cb,rb),cx);
    vec4 ink=mix(low,high,ry);
    COLOR=vec4(ink.rgb,ink.a*coverage);
}
