;; Sample the game's actual flashlight shader in an offscreen buffer.

(import (scheme base)
        (scheme python)
        (srfi 177)
        (only (world game) make-flashlight!)
        (only (world terrain) set-world-seed!)
        (only pathlib Path)
        (only panda3d.core CardMaker Geom GeomNode GeomTriangles GeomVertexData
              GeomVertexFormat GeomVertexWriter PNMImage Shader Vec3 loadPrcFileData)
        (only direct.showbase.ShowBase ShowBase))
(include "helpers.scm")

(test-begin "flashlight")
(set-world-seed! 4242)

;; Match Ursina's camera axes, including the offscreen shadow camera.
(loadPrcFileData "" "coordinate-system y-up-left\ngl-version 3 2\nwin-size 8 8\naudio-library-name null\nsync-video false\nframebuffer-srgb false")
(define flashlight-test-app (call/kw ShowBase (windowType "offscreen")))
;; Panda's UI root normally suppresses depth writes; shadow casters need the
;; same depth state as the game's 3D world, even for these small shader samples.
(call-method (attribute-ref flashlight-test-app 'render2d) 'set-depth-test #t)
(call-method (attribute-ref flashlight-test-app 'render2d) 'set-depth-write #t)
(define flashlight-test-source-node
  (make-flashlight! (attribute-ref flashlight-test-app 'cam2d)
                    (attribute-ref flashlight-test-app 'render2d)))
;; Optics are sampled without occluders first, then with shadow rendering on.
(call-method (call-method flashlight-test-source-node 'node) 'set-shadow-caster #f)
(call-method (attribute-ref flashlight-test-app 'render2d) 'set-shader-input "flashlight_shadows" 0.0)
(define flashlight-test-source
  (call-method
    (call-method
      (attribute-ref (attribute-ref (call-method (Path __file__) 'resolve) 'parent) 'parent)
      'joinpath "src" "shaders" "flashlight.glsl")
    'read-text))
(define flashlight-test-shader
  (call-method Shader 'make (attribute-ref Shader 'SL-GLSL)
    "#version 150\nuniform mat4 p3d_ModelViewProjectionMatrix;\nin vec4 p3d_Vertex;\nvoid main() { gl_Position = p3d_ModelViewProjectionMatrix * p3d_Vertex; }\n"
    (string-append "#version 150\n" flashlight-test-source
      "\nuniform vec3 sample_position;\nout vec4 frag_color;\nvoid main() { frag_color = vec4(flashlight_light(sample_position, vec3(0, 0, 1)), 1); }\n")))
(define flashlight-test-maker (CardMaker "flashlight samples"))
(call-method flashlight-test-maker 'set-frame -1 1 -1 1)
(define flashlight-test-card
  (call-method (attribute-ref flashlight-test-app 'render2d) 'attach-new-node
               (call-method flashlight-test-maker 'generate)))
(call-method flashlight-test-card 'set-shader flashlight-test-shader)
(call-method flashlight-test-card 'set-shader-input "flashlight" 1.0)

;; Red-channel radiance at a surface facing the viewer. Sampling the shader
;; itself catches projection changes without a second beam implementation.
(define (flashlight-sample x y z)
  (call-method flashlight-test-card 'set-shader-input "sample_position" (Vec3 x y z))
  (call-method (attribute-ref flashlight-test-app 'graphicsEngine) 'render-frame)
  (call-method (attribute-ref flashlight-test-app 'graphicsEngine) 'render-frame)
  (let ((pixels (PNMImage)))
    (call-method (attribute-ref flashlight-test-app 'win) 'get-screenshot pixels)
    (attribute-ref (call-method pixels 'get-xel 4 4) 'x)))

(define flashlight-center (flashlight-sample 0 0 -10))
(define flashlight-spill (flashlight-sample 7 0 -10))
(test-assert "the beam lights the surface it points at" (> flashlight-center 0.3))
(test-assert "dim spill lights rock beyond the main spot"
             (< 0.005 flashlight-spill (* 0.15 flashlight-center)))
(test-assert "nearby rock receives the beam from the player's right hand"
             (> (- (flashlight-sample 0.6 -0.18 -1.2)
                   (flashlight-sample -0.6 -0.18 -1.2))
                0.1))
(test-assert "the beam loses brightness with distance"
             (> (flashlight-sample 0 0 -5) flashlight-center (flashlight-sample 0 0 -18)))
(test-equal "rock beyond the flashlight's reach stays dark" 0.0 (flashlight-sample 0 0 -26))
(test-equal "the flashlight does not light behind the player" 0.0 (flashlight-sample 0 0 5))
(test-equal "spill is directional rather than an all-around glow" 0.0 (flashlight-sample 10 0 -1))
(call-method flashlight-test-card 'set-shader-input "flashlight" 0.0)
(test-equal "disabling the flashlight removes its spot" 0.0 (flashlight-sample 0 0 -10))
(test-equal "disabling the flashlight also removes its spill" 0.0 (flashlight-sample 7 0 -10))

;; This small quad blocks the ray from the hand to the sample eight meters
;; ahead. It is hidden from the viewer, so only its shadow can darken a sample.
(define flashlight-blocker-data
  (GeomVertexData "blocker" (call-method GeomVertexFormat 'get-v3) (attribute-ref Geom 'UH-static)))
(define flashlight-blocker-writer (GeomVertexWriter flashlight-blocker-data "vertex"))
(for-each (lambda (point) (apply call-method flashlight-blocker-writer 'add-data3f point))
          '((0.04 -0.20 4.0) (0.22 -0.20 4.0) (0.22 -0.02 4.0) (0.04 -0.02 4.0)))
(define flashlight-blocker-triangles (GeomTriangles (attribute-ref Geom 'UH-static)))
(call-method flashlight-blocker-triangles 'add-vertices 0 1 2)
(call-method flashlight-blocker-triangles 'add-vertices 0 2 3)
(define flashlight-blocker-geom (Geom flashlight-blocker-data))
(call-method flashlight-blocker-geom 'add-primitive flashlight-blocker-triangles)
(define flashlight-blocker-node (GeomNode "flashlight blocker"))
(call-method flashlight-blocker-node 'add-geom flashlight-blocker-geom)
(define flashlight-blocker
  (call-method (attribute-ref flashlight-test-app 'render2d) 'attach-new-node flashlight-blocker-node))
(call-method flashlight-blocker 'set-two-sided #t)
(call-method (call-method (attribute-ref flashlight-test-app 'cam2d) 'node) 'set-camera-mask 4)
(call-method flashlight-blocker 'hide 4)
(call-method flashlight-blocker 'set-x 2.0)
(call-method flashlight-test-card 'set-shader-input "flashlight" 1.0)
(call-method (call-method flashlight-test-source-node 'node) 'set-shadow-caster #t 1024 1024)
(call-method (attribute-ref flashlight-test-app 'render2d) 'set-shader-input "flashlight_shadows" 1.0)
(define flashlight-unblocked (flashlight-sample 0 0 -8))
(test-assert "the shadow map leaves an unblocked surface lit" (> flashlight-unblocked 0.3))
(call-method flashlight-blocker 'set-x 0.0)
(test-assert "an object between the flashlight and rock casts a shadow"
             (< (flashlight-sample 0 0 -8) (* 0.1 flashlight-unblocked)))
(call-method flashlight-blocker 'set-x 2.0)
(test-approximate "moving the object aside restores the light"
                  flashlight-unblocked (flashlight-sample 0 0 -8) 0.01)
(define flashlight-unblocked-spill (flashlight-sample 7 0 -10))
(test-assert "the shadow map leaves unblocked spill visible" (> flashlight-unblocked-spill 0.005))
(call-method flashlight-blocker 'set-pos 2.77 -0.02 0)
(test-assert "objects also cast shadows into the dim spill"
             (< (flashlight-sample 7 0 -10) (* 0.1 flashlight-unblocked-spill)))

;; Game meshes carry shaders that sample the flashlight's map themselves.
;; They must still write depth when rendered by its shadow camera.
(call-method flashlight-blocker 'set-shader flashlight-test-shader)
(call-method flashlight-blocker 'set-shader-input "flashlight" 1.0)
(call-method flashlight-blocker 'set-shader-input "sample_position" (Vec3 0 0 -8))
(call-method flashlight-blocker 'set-pos 0 0 0)
(test-assert "a shader-bearing mesh casts a shadow too"
             (< (flashlight-sample 0 0 -8) (* 0.1 flashlight-unblocked)))

;; In the game the camera is outside the chunks' subtree. A shadow camera
;; must still see those chunks from its actual position in the full scene.
(define flashlight-world (call-method (attribute-ref flashlight-test-app 'render2d) 'attach-new-node "world"))
(call-method flashlight-test-card 'reparent-to flashlight-world)
(call-method flashlight-blocker 'reparent-to flashlight-world)
(define flashlight-world-source
  (make-flashlight! (attribute-ref flashlight-test-app 'cam2d) flashlight-world))
(call-method flashlight-world 'set-shader-input "flashlight_shadows" 1.0)
(call-method (call-method flashlight-world-source 'node) 'set-shadow-caster #t 1024 1024)
(call-method flashlight-blocker 'set-x 2.0)
(test-assert "a separate world subtree receives the flashlight" (> (flashlight-sample 0 0 -8) 0.3))
(call-method flashlight-blocker 'set-x 0.0)
(test-assert "world geometry casts shadows when the camera is outside its subtree"
             (< (flashlight-sample 0 0 -8) (* 0.1 flashlight-unblocked)))

(call-method flashlight-test-app 'destroy)
(test-end "flashlight")
