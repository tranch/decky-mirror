from sqlalchemy import (
    Column,
    Integer,
    String,
    Boolean,
    DateTime,
    Text,
    ForeignKey,
)
from sqlalchemy.orm import relationship

from database import Base


class Plugin(Base):
    __tablename__ = "plugins"

    id = Column(Integer, primary_key=True, index=True)
    # Optional upstream id; you can use it to avoid duplicates when syncing
    upstream_id = Column(Integer, index=True, nullable=True)

    name = Column(String, index=True, nullable=False)
    author = Column(String, nullable=True)
    description = Column(Text, nullable=True)
    tags = Column(Text, nullable=True)  # store JSON text, e.g. '["acceleration"]'

    visible = Column(Boolean, default=True)
    image_url = Column(String, nullable=True)

    downloads = Column(Integer, default=0)
    updates = Column(Integer, default=0)

    created = Column(DateTime, nullable=True)
    updated = Column(DateTime, nullable=True)

    versions = relationship(
        "PluginVersion",
        back_populates="plugin",
        cascade="all, delete-orphan",
        lazy="joined",
    )


class PluginVersion(Base):
    __tablename__ = "plugin_versions"

    id = Column(Integer, primary_key=True, index=True)
    plugin_id = Column(Integer, ForeignKey("plugins.id"), nullable=False)

    name = Column(String, nullable=False)  # version name, e.g. "0.0.1"
    hash = Column(String, nullable=False)
    artifact = Column(String, nullable=True)  # URL or path to the artifact

    created = Column(DateTime, nullable=True)
    downloads = Column(Integer, default=0)
    updates = Column(Integer, default=0)

    plugin = relationship("Plugin", back_populates="versions")

