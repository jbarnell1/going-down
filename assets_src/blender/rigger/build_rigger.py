"""The Rigger (the Hanging Ward's resident) and his search hand, built from nothing.

Run from the repository root (no window; about a minute):

  tools/blender/blender-5.3.0-windows-x64/blender.exe --background --factory-startup --python-exit-code 1 --python assets_src/blender/rigger/build_rigger.py

Writes godot/assets/ward/rigger.glb (the figure, with its one climbing clip "Rigger Climb") and
godot/assets/ward/search-hand.glb (the hand at the end of the search arm: palm at the origin, a
"Wrist" marker, forward +Z). Every shape is made here from spheres and swept tubes; nothing is
imported. The first part (down to "The game files") is the review build of 18 Nov as it was made, so
the figure is the one that was reviewed; the preview lights, cameras and doorway it stages are not in
the exported collection.
"""
import bpy, bmesh, math, os, random, sys
from mathutils import Euler, Vector
from mathutils.noise import noise_vector
from math import sin,cos,pi
random.seed(31)
# Blender seeds its noise table at start-up differently each run; seed it so every build is identical.
import mathutils.noise
mathutils.noise.seed_set(31)
D=os.path.dirname(os.path.abspath(__file__))
b=bpy
b.ops.wm.read_factory_settings(use_empty=True)
s=b.context.scene
C=b.data.collections.new('RIGGER'); s.collection.children.link(C)
def empty(n,parent=None):
 o=b.data.objects.new(n,None); C.objects.link(o); o.parent=parent; return o
root=empty('Rigger.Root'); body=empty('Body / weight',root)
def mat(n,c,rough=.55,metal=0,noise=0):
 m=b.data.materials.new(n); m.diffuse_color=(*c,1); m.use_nodes=True; t=m.node_tree; p=t.nodes.get('Principled BSDF'); p.inputs['Base Color'].default_value=(*c,1); p.inputs['Roughness'].default_value=rough; p.inputs['Metallic'].default_value=metal
 if noise:
  tex=t.nodes.new('ShaderNodeTexNoise'); tex.inputs['Scale'].default_value=noise; tex.inputs['Detail'].default_value=4
  ramp=t.nodes.new('ShaderNodeValToRGB'); ramp.color_ramp.elements[0].position=.24; ramp.color_ramp.elements[0].color=(*[x*.30 for x in c],1); ramp.color_ramp.elements[1].position=.75; ramp.color_ramp.elements[1].color=(*[min(1,x*1.45) for x in c],1)
  t.links.new(tex.outputs['Fac'],ramp.inputs[0]); t.links.new(ramp.outputs[0],p.inputs['Base Color'])
  bump=t.nodes.new('ShaderNodeBump'); bump.inputs['Strength'].default_value=.23; bump.inputs['Distance'].default_value=.05; t.links.new(tex.outputs['Fac'],bump.inputs['Height']); t.links.new(bump.outputs[0],p.inputs['Normal'])
  grain=t.nodes.new('ShaderNodeTexNoise')
  grain.inputs['Scale'].default_value=noise*5
  grain.inputs['Detail'].default_value=2
  pores=t.nodes.new('ShaderNodeBump')
  pores.inputs['Strength'].default_value=.30
  pores.inputs['Distance'].default_value=.018
  t.links.new(grain.outputs['Fac'],pores.inputs['Height'])
  t.links.new(bump.outputs[0],pores.inputs['Normal'])
  t.links.new(pores.outputs[0],p.inputs['Normal'])
 return m
skin=mat('Drowned skin / mottled wax',(.255,.206,.177),.57,0,12)
shell=mat('Blood-dark pressure carapace',(.087,.043,.039),.49,0,10)
belly=mat('Distended underside',(.165,.093,.075),.61,0,18)
cord=mat('Exposed red sinew',(.14,.041,.033),.48,0,14)
coat=mat('Ochre oilskin remnants',(.26,.150,.047),.79,0,25)
iron=mat('Tarred iron',(.049,.061,.056),.38,.52,23)
ivory=mat('Horn / nail',(.52,.42,.29),.38,0,14)
black=mat('Orbital cavities',(.015,.009,.008),.48)
def mesh(n,v,f,m,p):
 me=b.data.meshes.new(n); me.from_pydata(v,[],f); me.update(); o=b.data.objects.new(n,me); C.objects.link(o); o.parent=p; me.materials.append(m)
 for q in me.polygons:q.use_smooth=True
 return o
def egg(n,pos,sc,m,p=body,detail=(28,16)):
 b.ops.mesh.primitive_uv_sphere_add(segments=detail[0],ring_count=detail[1]); o=b.context.object; o.name=n
 for c in list(o.users_collection):c.objects.unlink(o)
 C.objects.link(o); o.parent=p; o.location=pos; o.scale=sc; o.data.materials.append(m)
 for q in o.data.polygons:q.use_smooth=True
 return o
def sweep(n,pts,rs,m,p=body,k=10):
 pts=list(map(Vector,pts)); v=[]; faces=[]
 for i,(a,r) in enumerate(zip(pts,rs)):
  d=(pts[min(i+1,len(pts)-1)]-pts[max(0,i-1)]).normalized()
  x=d.cross(Vector((0,0,1)) if abs(d.z)<.94 else Vector((0,1,0))).normalized(); y=d.cross(x)
  for j in range(k): v.append(a+r*(x*cos(2*pi*j/k)+y*sin(2*pi*j/k)))
 for i in range(len(pts)-1):
  for j in range(k):a=i*k+j; u=i*k+(j+1)%k; faces.append((a,u,u+k,a+k))
 faces.extend([tuple(reversed(range(k))),tuple(range(len(v)-k,len(v)))])
 return mesh(n,v,faces,m,p)
# Build a deformed double-walled shell around two open apertures; the anterior right
# wound meets a second smaller split towards the rump. Both expose real negative space.
rind=mat('Rind / bruised plum through grey-brown',(.136,.090,.076),.63,0,9)
rind_tree=rind.node_tree
rind_ramp=next(node for node in rind_tree.nodes if node.type=='VALTORGB')
rind_ramp.color_ramp.elements[0].color=(.034,.020,.027,1)
rind_ramp.color_ramp.elements[1].color=(.196,.138,.097,1)
rind_ramp.color_ramp.elements.new(.45).color=(.071,.040,.051,1)
rind_ramp.color_ramp.elements.new(.59).color=(.116,.078,.067,1)
waste=mat('Wasted marbled tissue',(.31,.225,.162),.45,0,8)
inner=mat('Desiccated cavity lining',(.029,.012,.011),.82,0,17)
slough=mat('Sloughing dermis',(.141,.062,.034),.71,0,18)
tumor=mat('Bruised nodules / mineral green',(.093,.125,.073),.68,0,16)
pale=mat('Nodule crowns / wax',(.227,.207,.124),.62,0,24)
axis=Vector((.78,-.48,.40)).normalized()
u=axis.cross(Vector((0,0,1))).normalized()
v=axis.cross(u)
def rim_angle(a):
 return .93+.19*sin(2*a+.45)+.095*cos(5*a)+.04*sin(13*a+.8)+.025*sin(21*a)
def rear_angle(a):
 return pi-(.49+.17*cos(2*a-.6)+.08*sin(5*a))
def surface(t,a,depth=1):
 n=axis*cos(t)+(u*cos(a)+v*sin(a))*sin(t)
 x,y,z=n
 # Lower half sags and swells markedly on the animal's left.
 lump=1+.065*sin(y*5+x*3)*cos(z*4)+.043*noise_vector(n*3.1)[0]
 return Vector((-.22+2.13*x*(1+.16*y-.12*z)*lump*depth,
                1.56+2.56*y*(1+.10*x)*lump*depth,
                -.28+1.86*z*(1+.18*y)*lump*depth-.31*(1-z*z)*max(0,-x)-.17*y))
count=100; rows=39; vertices=[]; faces=[]; slots=[]
for layer in range(2):
 for j in range(rows):
  q=j/(rows-1)
  for k in range(count):
   a=2*pi*k/count; t=rim_angle(a)*(1-q)+rear_angle(a)*q
   vertices.append(surface(t,a,1 if not layer else .84+.038*sin(a*5+t*6)+.017*cos(9*a)))
def vi(l,j,k):return (l*rows+j)*count+k%count
for layer in range(2):
 for j in range(rows-1):
  for k in range(count):
   face=[vi(layer,j,k),vi(layer,j,k+1),vi(layer,j+1,k+1),vi(layer,j+1,k)]
   faces.append(face if layer==0 else face[::-1]); slots.append(2 if layer else 0)
for j in (0,rows-1):
 for k in range(count):
  faces.append([vi(0,j,k),vi(1,j,k),vi(1,j,k+1),vi(0,j,k+1)]);slots.append(3)
abd=mesh('Abdomen / hollow torn pressure sac',vertices,faces,rind,body)
for m in (waste,inner,slough):abd.data.materials.append(m)
for poly,slot in zip(abd.data.polygons,slots):poly.material_index=slot
# Both apertures connect an outer rind to an inner wall. Recalculate the orientation
# as one closed ring so the rim and cavity receive light on the intended sides.
bm=bmesh.new()
bm.from_mesh(abd.data)
bmesh.ops.recalc_face_normals(bm,faces=list(bm.faces))
bm.to_mesh(abd.data)
bm.free()
abd.data.update()
# Interrupted folded strips follow the wound edge; only a few bridge the black cavity.
for j in range(9):
 start=.18+j*.70; aa=[start+i*.027 for i in range(18)]
 sweep('Rolled ragged wound margin',[surface(rim_angle(a)+.016,a,1.006) for a in aa],
       [.009+.036*sin(pi*i/17)**.65 for i in range(18)],slough)
for j in (0,3,6):
 a=.48+j*.83
 p=surface(rim_angle(a),a,.93)
 q=surface(rim_angle(a+.78),a+.78,.91)
 sweep('Exposed attachment fibre',[p,p.lerp(q,.28)+Vector((0,.03,-.08)),p.lerp(q,.7)+Vector((0,.03,-.14)),q],[.046,.019,.011,.034],cord)
for j in (1,4,6,7):
 a=j*.77
 p=surface(rim_angle(a),a,.985)
 tip=p+Vector((-.05,.075,-(.20+.11*(j%3))))
 sweep('Detached skin tag',[p,p.lerp(tip,.42)+Vector((.035,0,0)),tip],[.057,.047,.008],slough)
# Buckled fibrous striae terminate on the wound shoulder.
for j in range(18):
 a=.12+j*.35
 total=.42+.4*random.random()
 paths=[surface(rim_angle(a)+.05+total*i/12,a+.05*sin(i*pi/12),1.003) for i in range(13)]
 sweep('Interrupted stretch scar',paths,[.007+.021*sin(pi*i/12)**.8 for i in range(13)],waste if j%3==0 else rind,k=7)
# Satellite clusters grow from three localized patches, grading in size away from scar.
growth_patches=[]
for a0,t0,num in ((.37,.16,18),(1.1,.32,10),(4.21,.15,15),(4.53,.60,9),(5.16,.85,6),(5.35,1.25,7)):
 patch=[]
 growth_patches.append(patch)
 for j in range(num):
  da=random.uniform(-.31,.31); dt=random.uniform(-.12,.18)
  a=a0+da; t=rim_angle(a)+t0+dt
  pos=surface(t,a,1.010); normal=(pos-Vector((-.22,1.56,-.3))).normalized()
  r=random.uniform(.045,.145)*(1.18-abs(da))*(1-.27*t0)
  o=egg('Clustered calcified growth',pos,(r*1.23,r*.91,r*.82),tumor if j%5 else pale,detail=(12,8))
  o.rotation_euler=normal.to_track_quat('Z','Y').to_euler()
  patch.append(o)
  for pt in o.data.vertices:
   pt.co*=1+.16*noise_vector(pt.co*3+Vector((j,0,0)))[0]
  if j%5==0:
   cap=egg('Sunken nodule core',pos+normal*r*.73,(r*.38,r*.29,r*.12),slough,detail=(10,6))
   cap.rotation_euler=o.rotation_euler
   patch.append(cap)
# Keep one mesh per lesion colony so individual polyps don't each cost a draw submission.
for idx, patch in enumerate(growth_patches):
 pv,pf,pm=[],[],[]
 mats=[tumor,pale,slough]
 b.context.view_layer.update()
 for part in patch:
  offset=len(pv)
  pv.extend(part.matrix_local@pt.co for pt in part.data.vertices)
  pf.extend(tuple(offset+i for i in face.vertices) for face in part.data.polygons)
  pm.extend([mats.index(part.data.materials[0])]*len(part.data.polygons))
 colony=mesh('Confluent lesion colony %02d'%idx,pv,pf,tumor,body)
 for m in mats[1:]:colony.data.materials.append(m)
 for face,index in zip(colony.data.polygons,pm):face.material_index=index
 for part in patch:b.data.objects.remove(part,do_unlink=True)

egg('Thorax / atrophied crew torso',(0,-.64,.12),(.83,.84,.64),belly)
egg('Collapsed jacket chest',(-.14,-1.08,.29),(.62,.39,.49),coat)
for side in (-1,1):
 pts=[(side*.72,-.31,.53),(side*.59,-.66,.77),(side*.45,-1.03,.65),(side*.40,-1.39,.13)]
 sweep('Grimy suspender',pts,[.065,.071,.070,.055],iron)
 sweep('Frayed jacket edge',[(side*.65,-.52,.53),(side*.69,-.91,.34),(side*.58,-1.12,.06),(side*.49,-1.14,-.12)],[.059,.056,.033,.012],coat)
 egg('Blackened suspender buckle',(side*.41,-1.31,.35),(.082,.040,.089),iron)
egg('Neck',(0,-1.28,.21),(.28,.40,.24),skin)
face=egg('Atrophied human head',(-.07,-1.57,.31),(.302,.283,.373),skin)
face.rotation_euler.y=-.23
egg('Jaw displaced below cheek',(-.012,-1.72,.032),(.156,.135,.158),skin)
for side in (-1,1):
 x=-.07+side*.114
 z=.371+side*.047
 egg('Recessed eye socket',(x,-1.812,z),(.077,.029,.052),black)
 if side>0:
  egg('Milky iris recessed in socket',(x+.017,-1.833,z-.014),(.016,.010,.014),belly)
 sweep('Weighted brow ridge',[(x-side*.08,-1.835,z+.040),(x,-1.841,z+.068),(x+side*.08,-1.786,z+.050)],[.024,.034,.014],skin)
 sweep('Sunken cheek',[(x+side*.10,-1.748,z),(x+side*.07,-1.816,z-.13),(x,-1.844,.131+side*.013)],[.046,.044,.017],skin)
 sweep('Tight throat tendon',[(side*.13,-1.62,.09),(side*.19,-1.53,-.09),(side*.27,-1.30,-.21)],[.039,.029,.011],skin)
egg('Crooked nasal bridge',(-.056,-1.854,.287),(.061,.086,.099),skin)
egg('Dark nostril',(-.025,-1.914,.222),(.035,.012,.018),black)
sweep('Torn lip opening',[(-.137,-1.821,.127),(-.058,-1.861,.108),(-.012,-1.867,.071),(.042,-1.826,.110)],[.010,.026,.025,.008],black)
for i in range(3):
 x=-.114+i*.037
 egg('Small exposed tooth',(x,-1.861,.108-i*.010),(.013,.007,.015),ivory)
hat=egg('Dented crew helmet',(-.095,-1.52,.597),(.347,.335,.181),coat)
hat.rotation_euler.y=-.27
brim=egg('Thin damaged brim',(-.107,-1.58,.572),(.385,.38,.032),iron)
brim.rotation_euler.y=-.27
egg('Dead headlamp housing',(-.183,-1.86,.620),(.087,.050,.083),iron)
egg('Cracked dark glass',(-.183,-1.905,.620),(.066,.016,.062),black)
sweep('Dragged crack in helmet',[(-.31,-1.74,.660),(-.25,-1.75,.704),(-.28,-1.63,.742),(-.20,-1.59,.760)],[.010,.013,.010,.006],black)
def keyed(o,fr):
 o.keyframe_insert(data_path='rotation_euler',frame=fr)
def pose(frame):
 climb=min(frame-1,48)
 phase=climb*pi/12
 stop=max(0,min(1,(49-frame)/9))
 # The hanging sac lags the next hold, then drops softly into the loaded side.
 side_load=sin(phase-.32)+.18*sin(3*phase-.6)
 translation=Vector((.19*side_load*stop,.036*sin(phase+.4)*stop,
                     climb*.017+.052*cos(2*phase+.28)*stop))
 rotation=Euler((.036*sin(phase-.37)*stop,.088*side_load*stop,.025*sin(phase+.5)*stop))
 return translation,rotation
def appendage(side,i,arm):
 a=empty(('Search arm' if arm else 'Hauling leg')+str((side,i)),body)
 a.location=(side*(.68 if arm else .83),-1.0 if arm else -.53+i*.60,.27)
 delta=Vector((side*(1.19 if arm else 1.88+i*.12+.055*side),-.54 if arm else (i-1)*.45,.21 if arm else 1.27+i*.12))
 end=Vector((side*(.22 if arm else .91),-1.86 if arm else .23*(i-1),-.58 if arm else -2.11-.12*i))
 zero=Vector((0,0,0))
 def shaft(n,d,p,m):
  if not arm:
   # Crooked bridges between offset knuckles, with wasting along the midshaft.
   sign=side*(1 if i%2 else -1)
   bow=Vector((.05*sign,.23*sign,-.12))
   ts=[0,.10,.19,.30,.43,.58,.71,.79,.91,1]
   offsets=[0,.16,.44,.82,.95,.32,-.23,-.53,-.26,0]
   pts=[d*t+bow*e for t,e in zip(ts,offsets)]
   radii=[.121,.164,.112,.079,.066,.060,.077,.094,.058,.078]
   sweep(n+' / kinked shaft',pts,radii,rind if n.startswith('Load') else shell,p,12)
   sweep('Raised longitudinal tendon',[pt+Vector((0,-.061,.022)) for pt in pts],[.020,.032,.025,.019,.027,.018,.015,.020,.015,.008],cord,p,7)
   for j in (1,7):
    kn=egg('Displaced knuckle',pts[j]+bow*.15,(.116,.097,.141),waste if i==1 else shell,p);kn.rotation_euler.y=side*.60
   if side==1 and i<2:
    for j in range(5):
     t=.07+j*.072; r=.083-j*.009
     egg('Satellite cyst on limb',d*t+bow*sin(t*pi)+Vector((.045,0,.036)),(r,r*.87,r*1.12),tumor,p)
   return
  bend=Vector((0,.065,-.093)); sweep(n,[zero,d*.13,d*.38+bend,d*.69+bend,d*.92,d],[.21,.235,.17,.113,.088,.102],m,p,14)
  sweep('Taut tendon',[zero+Vector((0,-.11,0)),d*.5+Vector((0,-.16,-.11)),d+Vector((0,-.05,0))],[.036,.029,.014],cord,p)
 shaft('Sleeve to elbow' if arm else 'Load bearing femur',delta,a,coat if arm else shell)
 joint=empty('Hinge',a); joint.location=delta; egg('Elbow boss',zero,(.173,.125,.135),shell,joint); shaft('Folded radius' if arm else 'Tibia',end,joint,skin if arm else shell)
 tip=empty('Palm or cable hook',joint); tip.location=end
 if arm:
  egg('Human palm',(0,-.19,.0),(.173,.232,.078),skin,tip)
  for j in range(4):
   x=side*(j-1.5)*.073
   length=[.325,.417,.372,.277][j]
   spread=side*(j-1.5)*.041
   curl=[.12,.16,.20,.17][j]
   pts=[(x,-.32,0),(x+spread,-.32-length*.47,-.021),
        (x+spread*1.19,-.32-length*.82,-curl*.50),(x+spread*1.23,-.32-length,-curl)]
   sweep('Searching finger',pts,[.053,.042,.029,.020],skin,tip)
   end_joint=Vector(pts[-1]); nail=egg('Worn fingernail',end_joint+Vector((0,.014,.015)),(.016,.029,.007),ivory,tip)
   nail.rotation_euler.x=.7
  sweep('Opposing human thumb',[(side*-.095,-.11,-.016),(side*-.23,-.22,-.047),
        (side*-.27,-.34,-.114),(side*-.245,-.416,-.153)],[.059,.051,.034,.023],skin,tip)
 else:
  sweep('Cable-gripping hook',[(0,0,0),(side*.08,.015,-.28),(-side*.065,.03,-.45),(-side*.22,.02,-.35)],[.115,.09,.06,.009],ivory,tip)
 for f in range(1,98):
  ph=(f-1)*2*pi/24+(i%2)*pi+(0 if side==1 else pi)
  if f<49:
   a.rotation_euler=(.105*sin(ph),side*.13*sin(ph),side*.05*cos(ph)); joint.rotation_euler=(.15*cos(ph),side*.20*max(0,sin(ph)),0)
  else:
   t=(f-49)/47; a.rotation_euler=(.13*sin(t*2*pi+side) if arm else .03,0,side*(.40*sin(t*pi*2+side*.7)-.27) if arm else 0); joint.rotation_euler=(.32*cos(t*2*pi+side) if arm else .03,0,-side*.28*sin(t*2*pi) if arm else 0)
  if arm and f>=49:
   # A palm probes, rests, then retracts. Offset the two hands so they do not sweep together.
   u=max(0,min(1,(f-49-(0 if side>0 else 12))/40))
   shape=lambda n: max(0,min(1,n))**2*(3-2*max(0,min(1,n)))
   reach=shape(u/.32)*(1-shape((u-.65)/.35))
   trace=shape((u-.31)/.30)
   goal=Vector((side*(1.58+.20*reach),-2.25-.90*reach,.12+.35*reach-.22*trace))-a.location
   direction=goal.normalized()
   bend=Vector((side*.9,0,.35))
   bend=(bend-direction*bend.dot(direction)).normalized()
   L=delta.length; M=end.length; dist=goal.length
   along=(L*L-M*M+dist*dist)/(2*dist)
   knee=direction*along+bend*max(.001,L*L-along*along)**.5
   q=delta.rotation_difference(knee)
   j=end.rotation_difference(q.inverted()@(goal-knee))
   a.rotation_euler=q.to_euler()
   joint.rotation_euler=j.to_euler()
   tip.rotation_euler=(q@j).inverted().to_euler()
   keyed(tip,f)
  if not arm:
   # A supporting talon stays at a fixed world height for half a stride.
   # The other tripod advances while load is transferred through the anchored side.
   phase=(0 if ((i+(side>0))%2==0) else 12)
   walk=min(f-1,48); cycle=(walk+phase)//24; frac=(walk+phase)%24
   lift=max(0,(frac-12)/12); lift=lift*lift*(3-2*lift)
   anchor=.408*(cycle+lift-phase/24)
   position,rotation=pose(f)
   world_contact=Vector((side*(3.50+i*.16),-.58+i*.99,-.50+anchor))
   goal=rotation.to_matrix().transposed()@(world_contact-position)-a.location
   direction=goal.normalized()
   # A moving bend plane lets the elbow wobble under load while both endpoints remain fixed.
   wobble=(.20*sin(ph-.45+.38*i)+.115*sin(2*ph+.7*side))*max(0,min(1,(49-f)/7))+.020*sin(f*.46+i*2)
   pole=Vector((.07*side,side*(wobble+.13*(i-1)),1))
   bend=(pole-direction*direction.dot(pole)).normalized()
   L=delta.length; M=end.length; dist=min(goal.length,L+M-.002)
   along=(L*L-M*M+dist*dist)/(2*dist)
   knee=direction*along+bend*max(.001,L*L-along*along)**.5
   q=delta.rotation_difference(knee); a.rotation_euler=q.to_euler()
   joint.rotation_euler=end.rotation_difference(q.inverted()@(goal-knee)).to_euler()
  # Resolve Euler wraps against the previous frame to keep subframe interpolation continuous.
  if f>1:
   a.rotation_euler=a.rotation_euler.to_quaternion().to_euler('XYZ',previous_a)
   joint.rotation_euler=joint.rotation_euler.to_quaternion().to_euler('XYZ',previous_joint)
  previous_a=a.rotation_euler.copy(); previous_joint=joint.rotation_euler.copy()
  keyed(a,f); keyed(joint,f)
for side in (-1,1):
 for i in range(3):appendage(side,i,False)
 appendage(side,0,True)
for f in range(1,98):
 body.location,body.rotation_euler=pose(f)
 body.keyframe_insert(data_path='location',frame=f); keyed(body,f)
# Preview staging is kept out of the linkable collection.
def stage(o):
 for c in list(o.users_collection):c.objects.unlink(o)
 s.collection.objects.link(o)
for side in (-1,1):
 for j in range(3):
  x=side*(3.50+j*.16); y=-.58+j*.99
  rope=sweep('Taut hoist line',[(x,y,-9),(x,y,9)],[.044,.044],iron,None,10); stage(rope)
def light(n,pos,power,color,size):
 b.ops.object.light_add(type='AREA',location=pos); o=b.context.object;o.name=n;o.data.energy=power;o.data.color=color;o.data.shape='DISK';o.data.size=size;o.rotation_euler=(Vector((0,0,0))-o.location).to_track_quat('-Z','Y').to_euler()
light('House lamp',(-3,-4,4),610,(1,.77,.50),2.8)
light('Cistern light',(3,5,3.7),1650,(.42,.65,.76),3.0)
light('Window bounce',(3,-4,1),115,(.86,.73,.61),3.6)
s.world=b.data.worlds.new('Buried void');s.world.use_nodes=True;s.world.node_tree.nodes['Background'].inputs[0].default_value=(.028,.040,.047,1);s.world.node_tree.nodes['Background'].inputs[1].default_value=.35
b.ops.object.camera_add(location=(8.0,-10.0,3.65));cam=b.context.object;cam.rotation_euler=(Vector((0,-.02,.17))-cam.location).to_track_quat('-Z','Y').to_euler();cam.data.type='ORTHO';cam.data.ortho_scale=9.45;s.camera=cam
s.render.engine='CYCLES';s.cycles.samples=6;s.cycles.use_denoising=True;s.render.resolution_x=1024;s.render.resolution_y=640;s.render.resolution_percentage=100;s.render.fps=24;s.frame_end=96
s.timeline_markers.new('Prey sensed / climb',frame=1);s.timeline_markers.new('House search',frame=49);s.frame_set(10)
# A separate camera faces through a standard domestic doorway. The jamb remains fixed in world.
climb_camera=cam
wood=mat('Damp painted wood',(.11,.088,.063),.81,0,19)
lintel=mat('Old painted jamb',(.16,.141,.110),.7,0,42)
def box(n,loc,dimensions,m):
 b.ops.mesh.primitive_cube_add(size=1,location=loc)
 o=b.context.object; o.name=n; o.dimensions=dimensions
 b.ops.object.transform_apply(location=False,rotation=False,scale=True)
 o.data.materials.append(m); bevel=o.modifiers.new('Worn edges','BEVEL'); bevel.width=.019; bevel.segments=2
 o.modifiers.new('Weighted corners','WEIGHTED_NORMAL')
 return o
house=[]
for side in (-1,1):
 for i in range(9):
  house.append(box('Split wall plank',(1.74+side*(.65+i*.237),-3.16,.88),(.231,.196,3.55),wood))
for x in (1.24,2.24):
 house.append(box('Door jamb / inner clear 0.9 m',(x,-3.16,.59),(.10,.24,2.20),lintel))
house.append(box('Door head / clear height 2.03 m',(1.74,-3.16,1.545),(1.1,.24,.12),lintel))
for i in range(5):
 house.append(box('Threshold and floorboards',(1.74,-3.13-i*.27,-.61),(3.05,.265,.18),wood))
b.ops.object.camera_add(location=(.6,-7.15,1.35))
door_camera=b.context.object; door_camera.name='Search / doorway scale'
door_camera.rotation_euler=(Vector((1.46,-2.4,.71))-door_camera.location).to_track_quat('-Z','Y').to_euler()
door_camera.data.lens=38
for o in house:
 o.hide_render=True
def search(value):
 s.camera=door_camera if value else climb_camera
 for o in house: o.hide_render=not value
s.camera=climb_camera

# ---- The game files.
from pathlib import Path
from mathutils import noise
ROOT = Path(D).resolve().parents[2]
OUT = ROOT / "godot" / "assets" / "ward"
OUT.mkdir(parents=True, exist_ok=True)

# The search hand: the parts under the forward right arm's hand, merged into one mesh around the palm and
# scaled to fit a 0.148 m sphere; flat PBR colours (the procedural albedo graph does not export).
arm = b.data.objects["Search arm(1, 0)"]
fore = next(part for part in arm.children if part.type == "EMPTY")
hand = next(part for part in fore.children if part.type == "EMPTY")
vertices, faces, slots, materials = [], [], [], []
for part in hand.children:
    if part.type != "MESH":
        continue
    material = part.data.materials[0]
    if material not in materials:
        materials.append(material)
    index = materials.index(material)
    offset = len(vertices)
    vertices.extend(part.matrix_local @ vertex.co for vertex in part.data.vertices)
    for face in part.data.polygons:
        faces.append(tuple(offset + i for i in face.vertices))
        slots.append(index)
mid = Vector((0, -.329, -.067))
factor = .148 / max((v - mid).length for v in vertices)
positions = [(v - mid) * factor for v in vertices]
hand_mesh = b.data.meshes.new("Approved Rigger hand")
hand_mesh.from_pydata(positions, [], faces)
# The hand is human skin, warmer than the wax of the body (the colour of the reviewed hand).
HUMAN = {"Drowned skin / mottled wax": ("Human skin / pore and livor variation", (.33, .261, .202, 1))}
for material in materials:
    name, colour = HUMAN.get(material.name, (material.name, material.diffuse_color))
    pbr = b.data.materials.new("Search / " + name)
    pbr.use_nodes = True
    principled = pbr.node_tree.nodes.get("Principled BSDF")
    principled.inputs["Base Color"].default_value = colour
    principled.inputs["Roughness"].default_value = .63
    hand_mesh.materials.append(pbr)
for face, index in zip(hand_mesh.polygons, slots):
    face.material_index = index
    face.use_smooth = True
hand_obj = b.data.objects.new("SearchHand", hand_mesh)
s.collection.objects.link(hand_obj)
marker = b.data.objects.new("Wrist", None)
s.collection.objects.link(marker)
marker.parent = hand_obj
marker.location = -mid * factor
b.ops.object.select_all(action="DESELECT")
hand_obj.select_set(True)
marker.select_set(True)
b.context.view_layer.objects.active = hand_obj
b.ops.export_scene.gltf(filepath=str(OUT / "search-hand.glb"), export_format="GLB", use_selection=True,
                        export_yup=True, export_animations=False)
print("HAND", len(positions), "vertices", len(faces), "faces", flush=True)

# The figure. glTF exports only Principled image textures and values: each material's procedural colouring
# goes onto the mesh as a mottled vertex colour over the flat base colour.
objects = C.all_objects
rig_mats = {slot.material for obj in objects if obj.type == "MESH"
            for slot in obj.material_slots if slot.material is not None}
for material in rig_mats:
    principled = next((node for node in material.node_tree.nodes if node.type == "BSDF_PRINCIPLED"), None)
    if principled is None:
        continue
    for channel in ("Base Color", "Normal"):
        for link in list(principled.inputs[channel].links):
            material.node_tree.links.remove(link)
    principled.inputs["Base Color"].default_value = material.diffuse_color
b.ops.object.select_all(action="DESELECT")
for obj in objects:
    obj.select_set(True)
    if obj.type != "MESH" or obj.data.color_attributes.get("DecayMottle") is not None:
        continue
    colors = obj.data.color_attributes.new(name="DecayMottle", type="FLOAT_COLOR", domain="POINT")
    obj.data.color_attributes.active_color = colors
    variant = sum(ord(c) for c in obj.name)
    span = Vector(tuple(max(0.08, component) for component in obj.dimensions))
    for vertex in obj.data.vertices:
        place = Vector((vertex.co.x / span.x, vertex.co.y / span.y, vertex.co.z / span.z))
        place += Vector((variant * 0.013, variant * 0.007, variant * 0.017))
        patches = noise.fractal(place * 6.0, 0.88, 2.1, 3)
        speckle = noise.noise(place * 46.0)
        value = max(0.30, min(1.0, 0.72 + patches * 0.46 + speckle * 0.17))
        colors.data[vertex.index].color = (value, value * 0.98, value * 0.95, 1.0)
# Each limb has its own object action; one shared NLA track name joins them into one clip, so every limb
# takes weight on the same clock in Godot.
for obj in objects:
    animation = obj.animation_data
    if animation is None or animation.action is None:
        continue
    action = animation.action
    slot = animation.action_slot
    track = animation.nla_tracks.new()
    track.name = "Rigger Climb"
    strip = track.strips.new("Rigger Climb", 1, action)
    if slot is not None:
        strip.action_slot = slot
    animation.action = None
s.frame_set(1)
b.ops.export_scene.gltf(filepath=str(OUT / "rigger.glb"), use_selection=True, export_animation_mode="NLA_TRACKS",
                        export_merge_animation="NLA_TRACK", export_cameras=False, export_lights=False,
                        export_vertex_color="ACTIVE")
print("RIGGER", sum(1 for o in objects if o.type == "MESH"), "meshes", flush=True)
