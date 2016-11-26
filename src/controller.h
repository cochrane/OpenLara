#ifndef H_CONTROLLER
#define H_CONTROLLER

#include "format.h"
#include "frustum.h"
#include "mesh.h"
#include "animation.h"

#define GRAVITY     (6.0f * 30.0f)
#define NO_OVERLAP  0x7FFFFFFF
#define SPRITE_FPS  10.0f

struct Controller {
    TR::Level   *level;
    int         entity;
    
    Animation   animation;
    int         &state;

    vec3    pos;
    vec3    angle;

    int     *meshes;
    int     mCount;

    struct ActionCommand {
        int             emitter;
        TR::Action      action;
        int             value;
        float           timer;
        ActionCommand   *next;

        ActionCommand() {}
        ActionCommand(int emitter, TR::Action action, int value, float timer, ActionCommand *next = NULL) : emitter(emitter), action(action), value(value), timer(timer), next(next) {}
    } *actionCommand;

    Controller(TR::Level *level, int entity) : level(level), entity(entity), animation(level, getModel()), state(animation.state), actionCommand(NULL), mCount(0), meshes(NULL) {
        TR::Entity &e = getEntity();
        pos       = vec3((float)e.x, (float)e.y, (float)e.z);
        angle     = vec3(0.0f, e.rotation, 0.0f);
    }

    virtual ~Controller() {
        delete[] meshes;
    }

    void initMeshOverrides() {
        TR::Model *model = getModel();
        mCount = model->mCount;
        meshes = mCount ? new int[mCount] : NULL;
        for (int i = 0; i < mCount; i++)
            meshes[i] = model->mStart + i;
    }

    void meshSwap(TR::Model *model, int mask = 0xFFFFFFFF) {
        if (!meshes) initMeshOverrides();

        for (int i = 0; i < model->mCount; i++) {
            int index = model->mStart + i;
            if (((1 << i) & mask) && level->meshOffsets[index])
                meshes[i] = index;
        }
    }

    bool aim(int target, int joint, const vec4 &angleRange, quat &rot, quat *rotAbs = NULL) {
        if (target > -1) {
            TR::Entity &e = level->entities[target];
            Box box = ((Controller*)e.controller)->getBoundingBox();
            vec3 t = (box.min + box.max) * 0.5f;

            mat4 m = animation.getJoints(getMatrix(), joint);
            vec3 delta = (m.inverse() * t).normal();

            float angleY = clampAngle(atan2(delta.x, delta.z));
            float angleX = clampAngle(asinf(delta.y));

            if (angleX > angleRange.x && angleX <= angleRange.y &&
                angleY > angleRange.z && angleY <= angleRange.w) {

                quat ax(vec3(1, 0, 0), -angleX);
                quat ay(vec3(0, 1, 0), angleY);

                rot = ay * ax;
                if (rotAbs)
                    *rotAbs = m.getRot() * rot;
                return true;
            }
        }

        if (rotAbs)
            *rotAbs = rotYXZ(angle);
        return false;
    }

    void updateEntity() {
        TR::Entity &e = getEntity();
        e.x = int(pos.x);
        e.y = int(pos.y);
        e.z = int(pos.z);
        while (angle.y < 0.0f)   angle.y += 2 * PI;
        while (angle.y > 2 * PI) angle.y -= 2 * PI;
        e.rotation = angle.y;
    }

    bool insideRoom(const vec3 &pos, int room) const {
        TR::Room &r = level->rooms[room];
        vec3 min = vec3((float)r.info.x, (float)r.info.yTop, (float)r.info.z);
        vec3 max = min + vec3(float(r.xSectors * 1024), float(r.info.yBottom - r.info.yTop), float(r.zSectors * 1024));

        return  pos.x >= min.x && pos.x <= max.x &&
                pos.y >= min.y && pos.y <= max.y &&
                pos.z >= min.z && pos.z <= max.z;
    }

    TR::Model* getModel() const {
        int index = getEntity().modelIndex;
        return index > 0 ? &level->models[index - 1] : NULL;
    }

    TR::Entity& getEntity() const {
        return level->entities[entity];
    }

    TR::Room& getRoom() const {
        int index = getRoomIndex();
        ASSERT(index >= 0 && index < level->roomsCount);
        return level->rooms[index];
    }

    virtual int getRoomIndex() const {
        return getEntity().room;
    }

    int getOverlap(int fromX, int fromY, int fromZ, int toX, int toZ) const {
        int dx, dz;
        TR::Room::Sector &s = level->getSector(getEntity().room, fromX, fromZ, dx, dz);
        
        if (s.boxIndex == 0xFFFF)
            return NO_OVERLAP;      

        TR::Box &b = level->boxes[s.boxIndex];
        if (b.contains(toX, toZ))
            return 0;

        int floor = NO_OVERLAP;
        int delta = NO_OVERLAP;

        TR::Overlap *o = &level->overlaps[b.overlap & 0x7FFF];
        do {
            TR::Box &ob = level->boxes[o->boxIndex];
            if (ob.contains(toX, toZ)) { // get min delta
                int d = abs(b.floor - ob.floor);
                if (d < delta) {
                    floor = ob.floor;
                    delta = d;
                }
            }
        } while (!(o++)->end);

        if (floor == NO_OVERLAP)
            return NO_OVERLAP;

        return b.floor - floor;
    }

    void playSound(int id, const vec3 &pos, int flags) const {
    //    LOG("play sound %d\n", id);

        int16 a = level->soundsMap[id];
        if (a == -1) return;

        TR::SoundInfo &b = level->soundsInfo[a];
        if (b.chance == 0 || (rand() & 0x7fff) <= b.chance) {
            int index = b.offset + rand() % b.flags.count;
            uint32 c = level->soundOffsets[index];
            void *p = &level->soundData[c];
            Sound::play(new Stream(p, 1024 * 1024), pos, (float)b.volume / 0xFFFF, 0.0f, flags | ((b.flags.replay == 1) ? Sound::REPLAY : 0), entity * 1000 + index);
        }
    }

    vec3 getDir() const {
        return vec3(angle.x, angle.y);
    }

    void alignToWall(float offset = 0.0f) {
        float fx = pos.x / 1024.0f;
        float fz = pos.z / 1024.0f;
        fx -= (int)fx;
        fz -= (int)fz;

        int k;
        if (fx > 1.0f - fz)
            k = fx < fz ? 0 : 1;
        else
            k = fx < fz ? 3 : 2;

        angle.y = k * PI * 0.5f;  // clamp angle to n*PI/2

        if (offset != 0.0f) {
            vec3 dir = getDir() * (512.0f - offset);
            if (k % 2)
                pos.x = int(pos.x / 1024.0f) * 1024.0f + 512.0f + dir.x;
            else
                pos.z = int(pos.z / 1024.0f) * 1024.0f + 512.0f + dir.z;
        }
        updateEntity();
    }

    virtual Box getBoundingBox() {
        return animation.getBoundingBox(pos, getEntity().rotation.value / 0x4000);
    }

    vec3 trace(int fromRoom, const vec3 &from, const vec3 &to, int &room, bool isCamera) { // TODO: use Bresenham
        room = fromRoom;

        vec3 pos = from, dir = to - from;
        int px = (int)pos.x, py = (int)pos.y, pz = (int)pos.z;

        float dist = dir.length();
        dir = dir * (1.0f / dist);

        int lr = -1, lx = -1, lz = -1;
        TR::Level::FloorInfo info;
        while (dist > 1.0f) {
            int sx = px / 1024 * 1024 + 512,
                sz = pz / 1024 * 1024 + 512;

            if (lr != room || lx != sx || lz != sz) {
                level->getFloorInfo(room, sx, py, sz, info);
                if (info.roomNext != 0xFF) {
                    room = info.roomNext;
                    level->getFloorInfo(room, sx, py, sz, info);
                }
                lr = room;
                lx = sx;
                lz = sz;
            }

            if (isCamera) {
                if (py > info.roomFloor && info.roomBelow != 0xFF)
                    room = info.roomBelow;
                else if (py < info.roomCeiling && info.roomAbove != 0xFF)
                    room = info.roomAbove;
                else if (py > info.floor || py < info.ceiling) {
                    int minX = px / 1024 * 1024;
                    int minZ = pz / 1024 * 1024;
                    int maxX = minX + 1024;
                    int maxZ = minZ + 1024;

                    pos = vec3(float(clamp(px, minX, maxX)), pos.y, float(clamp(pz, minZ, maxZ))) + boxNormal(px, pz) * 256.0f;
                    dir = (pos - from).normal();
                }
            } else {
                if (py > info.roomFloor) {
                    if (info.roomBelow != 0xFF) 
                        room = info.roomBelow;
                    else
                        break;
                }

                if (py < info.roomCeiling) {
                    if (info.roomAbove != 0xFF)
                        room = info.roomAbove;
                    else
                        break;
                }
            }

            float d = min(dist, 32.0f);    // STEP = 32
            dist -= d;
            pos = pos + dir * d;

            px = (int)pos.x, py = (int)pos.y, pz = (int)pos.z;
        }

        return pos;
    }

    void doBubbles() {
        if (rand() % 10 <= 6) return;
        playSound(TR::SND_BUBBLE, pos, Sound::Flags::PAN);
    }

    void activateNext() { // activate next entity (for triggers)
        if (!actionCommand || !actionCommand->next) {
            actionCommand = NULL;
            return;
        }
        ActionCommand *next = actionCommand->next;

        Controller *controller = NULL;
        switch (next->action) {
            case TR::Action::ACTIVATE        :
                controller = (Controller*)level->entities[next->value].controller;
                break;
            case TR::Action::CAMERA_SWITCH   :
            case TR::Action::CAMERA_TARGET   :
                controller = (Controller*)level->cameraController;
                break;
            case TR::Action::SECRET          :
                if (!level->secrets[next->value]) {
                    level->secrets[next->value] = true;
                    playSound(TR::SND_SECRET, pos, 0);
                }
                actionCommand = next;
                activateNext();
                return;
            case TR::Action::FLOW            :
            case TR::Action::FLIP_MAP        :
            case TR::Action::FLIP_ON         :
            case TR::Action::FLIP_OFF        :
            case TR::Action::END             :
            case TR::Action::SOUNDTRACK      :
            case TR::Action::HARDCODE        :
            case TR::Action::CLEAR           :
            case TR::Action::CAMERA_FLYBY    :
            case TR::Action::CUTSCENE        :
                break;
        }

        if (controller) {
            if (controller->activate(next))
                actionCommand = NULL;
        } else
            actionCommand = NULL;
    }

    virtual bool  activate(ActionCommand *cmd)  { actionCommand = cmd; return true; } 
    virtual void  doCustomCommand               (int curFrame, int prevFrame) {}
    virtual void  checkRoom()                   {}

    virtual void  cmdOffset(const vec3 &offset) {
        pos = pos + offset.rotateY(-angle.y);
        updateEntity();
        checkRoom();
    }

    virtual void  cmdJump(const vec3 &vel)      {}
    virtual void  cmdKill()                     {}
    virtual void  cmdEmpty()                    {}


    virtual void updateAnimation(bool commands) {
        animation.update();
        
        TR::Animation *anim = animation;

    // apply animation commands
        if (commands) {
            int16 *ptr = &level->commands[anim->animCommand];

            for (int i = 0; i < anim->acCount; i++) {
                int cmd = *ptr++; 
                switch (cmd) {
                    case TR::ANIM_CMD_OFFSET : ptr += 3;   break;
                    case TR::ANIM_CMD_JUMP   : ptr += 2;   break;      
                    case TR::ANIM_CMD_EMPTY  : cmdEmpty(); break;
                    case TR::ANIM_CMD_KILL   : cmdKill();  break;
                    case TR::ANIM_CMD_SOUND  :
                    case TR::ANIM_CMD_EFFECT : {
                        int frame = (*ptr++) - anim->frameStart;
                        int fx    = (*ptr++) & 0x3FFF;
                        if (animation.isFrameActive(frame)) {
                            if (cmd == TR::ANIM_CMD_EFFECT) {
                                switch (fx) {
                                    case TR::EFFECT_ROTATE_180     : angle.y = angle.y + PI; break;
                                    case TR::EFFECT_LARA_BUBBLES   : doBubbles(); break;
                                    case TR::EFFECT_LARA_HANDSFREE : break;
                                    default : LOG("unknown special cmd %d (anim %d)\n", fx, animation.index);
                                }
                            } else
                                playSound(fx, pos, Sound::Flags::PAN);
                        }
                        break;
                    }
                }
            }
        }

        if (animation.frameIndex != animation.framePrev)
            doCustomCommand(animation.frameIndex, animation.framePrev);

        if (animation.isEnded) { // if animation is end - switch to next
            if (animation.offset != 0.0f) cmdOffset(animation.offset);
            if (animation.jump   != 0.0f) cmdJump(animation.jump);
            animation.playNext();
            activateNext();
        } else
            animation.framePrev = animation.frameIndex;
    }
    
    virtual void update() {
        updateAnimation(true);
    }
    
    void renderMesh(const mat4 &matrix, MeshBuilder *mesh, uint32 offsetIndex) {
        MeshBuilder::MeshInfo *mInfo = mesh->meshMap[offsetIndex];
        if (!mInfo) return; // invisible mesh (offsetIndex > 0 && level.meshOffsets[offsetIndex] == 0) camera target entity etc.
        
        Core::active.shader->setParam(uModel, matrix);
        mesh->renderMesh(mInfo);
    }

    void renderShadow(MeshBuilder *mesh, const vec3 &pos, const vec3 &offset, const vec3 &size, float angle) {
        mat4 m;
        m.identity();
        m.translate(pos);
        m.rotateY(angle);
        m.translate(vec3(offset.x, 0.0f, offset.z));
        m.scale(vec3(size.x, 0.0f, size.z) * (1.0f / 1024.0f));

        Core::active.shader->setParam(uModel, m);
        Core::active.shader->setParam(uColor, vec4(0.0f, 0.0f, 0.0f, 0.5f));
        Core::active.shader->setParam(uAmbient, vec3(0.0f));
        mesh->renderShadowSpot();
    }

    mat4 getMatrix() {
        mat4 matrix;
        matrix.identity();
        matrix.translate(pos);
        if (angle.y != 0.0f) matrix.rotateY(angle.y - (animation.flip ? PI * animation.delta : 0.0f));
        if (angle.x != 0.0f) matrix.rotateX(angle.x);
        if (angle.z != 0.0f) matrix.rotateZ(angle.z);
        return matrix;
    }

    virtual void render(Frustum *frustum, MeshBuilder *mesh) { // TODO: animation.calcJoints
        mat4 matrix = getMatrix();

        Box box = animation.getBoundingBox(vec3(0, 0, 0), 0);
        if (frustum && !frustum->isVisible(matrix, box.min, box.max))
            return;

        TR::Entity &entity = getEntity();
        TR::Model  *model  = getModel();
        entity.flags.rendered = true;

        mat4 joints[32]; // TODO: UBO heap
        ASSERT(model->mCount <= 32);

        animation.getJoints(matrix, -1, true, joints);
        for (int i = 0; i < model->mCount; i++)
            renderMesh(joints[i], mesh, meshes ? meshes[i] : (model->mStart + i));

        if (TR::castShadow(entity.type)) {
            TR::Level::FloorInfo info;
            level->getFloorInfo(entity.room, entity.x, entity.y, entity.z, info);
            renderShadow(mesh, vec3(float(entity.x), info.floor - 16.0f, float(entity.z)), box.center(), box.size() * 0.8f, angle.y);
        }
    }
};

#endif