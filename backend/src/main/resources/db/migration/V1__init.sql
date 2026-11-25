-- =====================================================================
-- TrazaPort - Migración inicial V1__init.sql (PostgreSQL)
-- =====================================================================

-- Extensión para generación de UUID si se requiere en la base
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- 1. Roles y Usuarios
CREATE TABLE roles (
    id SMALLINT PRIMARY KEY,
    nombre VARCHAR(30) NOT NULL UNIQUE
        CHECK (nombre IN (
            'ADMIN',
            'JEFE_OPERACIONES',
            'ENCARGADO_INVENTARIO',
            'ENCARGADO_DOCUMENTAL',
            'OPERADOR',
            'PORTERIA',
            'CLIENTE'
        ))
);

INSERT INTO roles (id, nombre) VALUES
    (1, 'ADMIN'),
    (2, 'JEFE_OPERACIONES'),
    (3, 'ENCARGADO_INVENTARIO'),
    (4, 'ENCARGADO_DOCUMENTAL'),
    (5, 'OPERADOR'),
    (6, 'PORTERIA'),
    (7, 'CLIENTE')
ON CONFLICT (id) DO NOTHING;

CREATE TABLE clientes (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    rut VARCHAR(12) NOT NULL UNIQUE,
    razon_social VARCHAR(150) NOT NULL,
    tipo VARCHAR(15) NOT NULL
        CHECK (tipo IN ('IMPORTADOR', 'EXPORTADOR', 'AGENTE')),
    email_contacto VARCHAR(120),
    activo BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE usuarios (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    rol_id SMALLINT NOT NULL REFERENCES roles(id),
    cliente_id UUID REFERENCES clientes(id),
    email VARCHAR(120) NOT NULL UNIQUE,
    password_hash VARCHAR(100) NOT NULL,
    nombre_completo VARCHAR(120) NOT NULL,
    activo BOOLEAN NOT NULL DEFAULT TRUE,
    intentos_fallidos SMALLINT NOT NULL DEFAULT 0,
    bloqueado_hasta TIMESTAMPTZ,
    creado_en TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 2. Documentos de transporte y Recepciones
CREATE TABLE documentos_transporte (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    cliente_id UUID NOT NULL REFERENCES clientes(id),
    numero_bl VARCHAR(30) NOT NULL UNIQUE,
    manifiesto VARCHAR(30),
    naviera VARCHAR(60),
    nave_viaje VARCHAR(60),
    tipo_operacion VARCHAR(15) NOT NULL
        CHECK (tipo_operacion IN ('IMPORTACION', 'EXPORTACION')),
    cantidad_declarada INT NOT NULL CHECK (cantidad_declarada > 0),
    peso_declarado_kg NUMERIC(12,2),
    estado_aduanero VARCHAR(25) NOT NULL
        CHECK (estado_aduanero IN ('PENDIENTE_DESTINACION', 'AUTORIZADO', 'RETENIDO')),
    fecha_pre_aviso DATE
);

CREATE TABLE recepciones (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    documento_id UUID NOT NULL REFERENCES documentos_transporte(id),
    usuario_id UUID NOT NULL REFERENCES usuarios(id),
    patente_camion VARCHAR(10) NOT NULL,
    nombre_conductor VARCHAR(100) NOT NULL,
    sello_recibido VARCHAR(30),
    peso_recibido_kg NUMERIC(12,2),
    cantidad_recibida INT NOT NULL CHECK (cantidad_recibida >= 0),
    fecha_hora TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    estado VARCHAR(20) NOT NULL
        CHECK (estado IN ('CONFORME', 'CON_OBSERVACIONES'))
);

-- 3. Ubicaciones y Unidades Logísticas
CREATE TABLE ubicaciones (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    codigo VARCHAR(20) NOT NULL UNIQUE,
    zona VARCHAR(20) NOT NULL,
    fila SMALLINT NOT NULL,
    posicion SMALLINT NOT NULL,
    nivel SMALLINT NOT NULL DEFAULT 1,
    capacidad SMALLINT NOT NULL CHECK (capacidad > 0),
    activa BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE unidades_logisticas (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    codigo_corto CHAR(8) NOT NULL UNIQUE,
    codigo_qr VARCHAR(40) UNIQUE,
    tipo VARCHAR(10) NOT NULL
        CHECK (tipo IN ('PALLET', 'CAJA', 'BULTO', 'CONTENEDOR')),
    padre_id UUID REFERENCES unidades_logisticas(id),
    documento_id UUID NOT NULL REFERENCES documentos_transporte(id),
    cliente_id UUID NOT NULL REFERENCES clientes(id),
    recepcion_id UUID NOT NULL REFERENCES recepciones(id),
    ubicacion_id UUID REFERENCES ubicaciones(id),
    descripcion VARCHAR(200) NOT NULL,
    cantidad INT NOT NULL CHECK (cantidad > 0),
    peso_kg NUMERIC(12,2),
    estado_fisico VARCHAR(20) NOT NULL
        CHECK (estado_fisico IN ('SIN_DANOS', 'DANADO')),
    estado_aduanero VARCHAR(25) NOT NULL
        CHECK (estado_aduanero IN ('PENDIENTE_DESTINACION', 'LIBERADA', 'RETENIDA')),
    estado_operativo VARCHAR(20) NOT NULL
        CHECK (estado_operativo IN ('ALMACENADA', 'EN_INSPECCION', 'PREPARADA', 'DESPACHADA')),
    fecha_ingreso TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    fecha_limite_permanencia DATE,
    version INT NOT NULL DEFAULT 0
);

-- 4. Historial de trazabilidad (solo agregado / append-only)
CREATE TABLE eventos_trazabilidad (
    id BIGSERIAL PRIMARY KEY,
    unidad_id UUID NOT NULL REFERENCES unidades_logisticas(id),
    id_cliente UUID UNIQUE,
    origen VARCHAR(10) NOT NULL DEFAULT 'EN_LINEA'
        CHECK (origen IN ('EN_LINEA', 'OFFLINE', 'DIFERIDO')),
    tipo_evento VARCHAR(25) NOT NULL
        CHECK (tipo_evento IN (
            'INGRESO',
            'INSPECCION',
            'ALMACENAMIENTO',
            'REUBICACION',
            'AFORO',
            'DESCONSOLIDACION',
            'PREPARACION',
            'DESPACHO',
            'AJUSTE'
        )),
    fecha_hora_evento TIMESTAMPTZ NOT NULL,
    fecha_hora_registro TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    ubicacion_origen_id UUID REFERENCES ubicaciones(id),
    ubicacion_destino_id UUID REFERENCES ubicaciones(id),
    usuario_id UUID NOT NULL REFERENCES usuarios(id),
    equipo VARCHAR(40),
    documento_ref VARCHAR(60),
    observaciones TEXT,
    hash_anterior CHAR(64),
    hash_evento CHAR(64) NOT NULL
);

-- 5. Despachos
CREATE TABLE despachos (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    cliente_id UUID NOT NULL REFERENCES clientes(id),
    estado VARCHAR(15) NOT NULL
        CHECK (estado IN ('SOLICITADO', 'VALIDADO', 'BLOQUEADO', 'EJECUTADO')),
    motivo_bloqueo VARCHAR(200),
    patente_vehiculo VARCHAR(10),
    nombre_conductor VARCHAR(100),
    documento_ref VARCHAR(60),
    ejecutado_por UUID REFERENCES usuarios(id),
    fecha_solicitud TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    fecha_salida TIMESTAMPTZ
);

CREATE TABLE despacho_detalle (
    despacho_id UUID NOT NULL REFERENCES despachos(id),
    unidad_id UUID NOT NULL REFERENCES unidades_logisticas(id),
    cantidad INT NOT NULL CHECK (cantidad > 0),
    PRIMARY KEY (despacho_id, unidad_id)
);

-- 6. Auditoría
CREATE TABLE auditoria (
    id BIGSERIAL PRIMARY KEY,
    usuario_id UUID REFERENCES usuarios(id),
    accion VARCHAR(40) NOT NULL,
    entidad VARCHAR(40),
    entidad_id UUID,
    valor_anterior JSONB,
    valor_nuevo JSONB,
    ip_origen INET,
    fecha_hora TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Protección append-only: impide UPDATE y DELETE en eventos_trazabilidad y auditoria
CREATE OR REPLACE FUNCTION bloquear_modificacion_historial()
RETURNS TRIGGER AS $$
BEGIN
    RAISE EXCEPTION 'La tabla % es de solo agregado (append-only) y no permite %', TG_TABLE_NAME, TG_OP;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_no_update_delete_eventos
BEFORE UPDATE OR DELETE ON eventos_trazabilidad
FOR EACH ROW EXECUTE FUNCTION bloquear_modificacion_historial();

CREATE TRIGGER trg_no_update_delete_auditoria
BEFORE UPDATE OR DELETE ON auditoria
FOR EACH ROW EXECUTE FUNCTION bloquear_modificacion_historial();