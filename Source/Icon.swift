import AppKit
let sizes = [16,32,64,128,256,512,1024]
let directory = CommandLine.arguments[1]
for size in sizes {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let s = CGFloat(size)
    let box = NSRect(x: s*0.055,y:s*0.055,width:s*0.89,height:s*0.89)
    let path = NSBezierPath(roundedRect:box,xRadius:s*0.21,yRadius:s*0.21)
    NSGradient(starting:NSColor(red:0.12,green:0.76,blue:0.74,alpha:1),ending:NSColor(red:0.025,green:0.25,blue:0.36,alpha:1))!.draw(in:path,angle:-60)
    NSColor.white.withAlphaComponent(0.25).setStroke(); path.lineWidth=s*0.012; path.stroke()
    let pane = NSBezierPath(roundedRect:NSRect(x:s*0.21,y:s*0.28,width:s*0.58,height:s*0.46),xRadius:s*0.065,yRadius:s*0.065)
    NSColor.white.withAlphaComponent(0.18).setFill(); pane.fill()
    NSColor.white.withAlphaComponent(0.9).setStroke(); pane.lineWidth=s*0.022; pane.stroke()
    let line = NSBezierPath(); line.move(to: NSPoint(x:s*0.22,y:s*0.62)); line.line(to:NSPoint(x:s*0.78,y:s*0.62)); line.lineWidth=s*0.016; line.stroke()
    for x in [0.28,0.33,0.38] { NSColor.white.withAlphaComponent(0.85).setFill(); NSBezierPath(ovalIn:NSRect(x:s*x,y:s*0.662,width:s*0.02,height:s*0.02)).fill() }
    let pulse = NSBezierPath(); pulse.move(to:NSPoint(x:s*0.30,y:s*0.44)); for (x,y) in [(0.40,0.44),(0.46,0.53),(0.53,0.36),(0.59,0.44),(0.70,0.44)] { pulse.line(to:NSPoint(x:s*x,y:s*y)) }; pulse.lineJoinStyle = .round; pulse.lineCapStyle = .round; pulse.lineWidth=s*0.028; pulse.stroke()
    NSColor(red:0.45,green:1,blue:0.73,alpha:1).setFill(); NSBezierPath(ovalIn:NSRect(x:s*0.70,y:s*0.22,width:s*0.12,height:s*0.12)).fill()
    image.unlockFocus()
    let rep = NSBitmapImageRep(data:image.tiffRepresentation!)!
    let data = rep.representation(using:.png,properties:[:])!
    try data.write(to:URL(fileURLWithPath:"\(directory)/\(size).png"))
}
