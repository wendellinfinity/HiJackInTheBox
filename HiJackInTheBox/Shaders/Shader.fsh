//
//  Shader.fsh
//  HiJackInTheBox
//
//  Created by Wendell on 21/08/2011.
//  Copyright 2011 __MyCompanyName__. All rights reserved.
//

varying lowp vec4 colorVarying;

void main()
{
    gl_FragColor = colorVarying;
}
