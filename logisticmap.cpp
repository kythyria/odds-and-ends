/**
 * LADSPA plugin to generate noise based on the logistic map function.
 * 
 * Compile with `g++ -o logisticmap.so -shared logisticmap.cpp`
 * 
 * GPLv2 or later, if anyone cares.
 * 
 * Don't set seed to 0 or 1, you'll get silence.
 */

#include <ladspa.h>

#define NULL 0

#define PLUGIN_BASE 1
#define PLUGIN_ID(x) (PLUGIN_BASE + x)

LADSPA_Handle lmng_new(const LADSPA_Descriptor *desc, unsigned long samplerate);
void lmng_connect(LADSPA_Handle instance, unsigned long port, LADSPA_Data *location);
void lmng_activate(LADSPA_Handle instance);
void lmng_run(LADSPA_Handle instance, unsigned long sampleCount);
void lmng_delete(LADSPA_Handle instance);

class lmng_state
{
public:
    LADSPA_Data *r;
    LADSPA_Data *seed;
    LADSPA_Data *outbuf;
    LADSPA_Data current;
};

const unsigned long PORT_R     = 0;
const unsigned long PORT_SEED  = 1;
const unsigned long PORT_OUT   = 2;
const unsigned long PORT_COUNT = 3;

const LADSPA_PortDescriptor plugin_ports[PORT_COUNT] = {
    LADSPA_PORT_INPUT | LADSPA_PORT_CONTROL,
    LADSPA_PORT_INPUT | LADSPA_PORT_CONTROL,
    LADSPA_PORT_OUTPUT | LADSPA_PORT_AUDIO
};

const char* const plugin_portnames[PORT_COUNT] = {
    "R (float 0-4)",
    "Seed value (float)",
    "Noise"
};

const LADSPA_PortRangeHint plugin_hints[PORT_COUNT] = {
    {
        LADSPA_HINT_BOUNDED_BELOW | LADSPA_HINT_BOUNDED_ABOVE | LADSPA_HINT_DEFAULT_HIGH,
        0.0f,
        4.0f
    },
    {
        LADSPA_HINT_BOUNDED_BELOW | LADSPA_HINT_BOUNDED_ABOVE | LADSPA_HINT_DEFAULT_0,
        0.0f,
        1.0f
    },
    {
        LADSPA_HINT_BOUNDED_BELOW | LADSPA_HINT_BOUNDED_ABOVE,
        0.0f,
        1.0f
    }
};

const LADSPA_Descriptor plugin = {
    PLUGIN_ID(0),
    "LogisticMapGenerator",
    0,
    "Logistic Map noise generator",
    "Kythyria Tieran",
    "None",
    PORT_COUNT,
    plugin_ports,
    plugin_portnames,
    plugin_hints,
    NULL,
    lmng_new,
    lmng_connect,
    lmng_activate,
    lmng_run,
    NULL,
    NULL,
    NULL,
    lmng_delete
};

const LADSPA_Descriptor * ladspa_descriptor(unsigned long Index)
{
    if(Index > 0)
    {
        return NULL;
    }
    
    return &plugin;
}

LADSPA_Handle lmng_new(const LADSPA_Descriptor *desc, unsigned long samplerate)
{
    if (desc != &plugin) { return NULL; }
    return new lmng_state();
}
void lmng_delete(LADSPA_Handle instance)
{
    delete (lmng_state*)instance;
}

void lmng_connect(LADSPA_Handle instance, unsigned long port, LADSPA_Data *location)
{
    lmng_state *inst = (lmng_state*)instance;
    switch(port)
    {
        case PORT_R:
            inst->r = location;
            break;
        case PORT_SEED:
            inst->seed = location;
            break;
        case PORT_OUT:
            inst->outbuf = location;
            break;
    }
}

void lmng_activate(LADSPA_Handle instance)
{
    lmng_state *inst = (lmng_state*)instance;
    inst->current = *(inst->seed);
}

void lmng_run(LADSPA_Handle instance, unsigned long sampleCount)
{
    lmng_state *inst = (lmng_state*)instance;
    LADSPA_Data r = *(inst->r);
    if (r > 4.0f) { r = 4.0f; }
    if (r < 0.0f) { r = 0.0f; }
    
    for (int i = 0; i < sampleCount; ++i)
    {
        inst->outbuf[i] = inst->current; //0.5f;
        inst->current = r * inst->current * (1 - inst->current);
    }
}