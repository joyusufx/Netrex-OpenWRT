"""Pydantic helpers that work on both v2 and v1.

``pydantic`` v2 is built on ``pydantic-core``, a Rust extension for which no
MIPS wheels exist, so the OpenWrt installer pins the pure-Python stack
(fastapi 0.115 + pydantic 1.10). The API models use the v2 spellings, so this
module maps the handful of them onto their v1 equivalents and the same
schemas run unchanged on both.
"""

from __future__ import annotations

from typing import get_origin

import pydantic

PYDANTIC_V2 = int(pydantic.version.VERSION.split(".", 1)[0]) >= 2

if PYDANTIC_V2:
    from pydantic import BaseModel, Field, field_validator  # noqa: F401
else:  # pydantic 1.x (pure Python, installable on MIPS)
    from pydantic import BaseModel as _BaseModel
    from pydantic import Field as _V1Field
    from pydantic import validator as _V1Validator
    from pydantic.fields import ModelField as _V1ModelField

    _UNSET = object()
    #: v2 length constraints for sequences are applied in __init_subclass__,
    #: once the pydantic v1 ModelField knows whether the value is a sequence.
    _MAX_LENGTH = "_compat_max_length"
    _MIN_LENGTH = "_compat_min_length"
    _SEQUENCE_ORIGINS = (list, tuple, set, frozenset)

    class BaseModel(_BaseModel):
        """pydantic v1 model exposing the v2 spellings the API models use."""

        def __init_subclass__(cls, **kwargs):
            super().__init_subclass__(**kwargs)
            for name, field in list(cls.__fields__.items()):
                extra = field.field_info.extra
                if _MAX_LENGTH not in extra and _MIN_LENGTH not in extra:
                    continue
                max_len = extra.pop(_MAX_LENGTH, None)
                min_len = extra.pop(_MIN_LENGTH, None)
                info = field.field_info
                is_sequence = get_origin(field.outer_type_) in _SEQUENCE_ORIGINS
                if max_len is not None:
                    if is_sequence:
                        info.max_items = max_len
                    else:
                        info.max_length = max_len
                if min_len is not None:
                    if is_sequence:
                        info.min_items = min_len
                    else:
                        info.min_length = min_len
                cls.__fields__[name] = _V1ModelField.infer(
                    name=name, value=info, annotation=field.annotation,
                    class_validators=field.class_validators, config=cls.__config__)

        def model_dump(self, **kwargs):
            return self.dict(**kwargs)

    def Field(default=_UNSET, **kwargs):  # noqa: N802 — mirrors pydantic.Field
        """``Field`` with the v2 names ``pattern``/``max_length`` mapped for v1."""
        if "pattern" in kwargs:
            kwargs["regex"] = kwargs.pop("pattern")
        if "max_length" in kwargs:
            kwargs[_MAX_LENGTH] = kwargs.pop("max_length")
        if "min_length" in kwargs:
            kwargs[_MIN_LENGTH] = kwargs.pop("min_length")
        if default is _UNSET:
            return _V1Field(**kwargs)
        return _V1Field(default, **kwargs)

    def field_validator(*fields, **kwargs):  # noqa: N802 — mirrors pydantic
        """v2 ``field_validator`` decorator backed by the v1 ``validator``."""
        kwargs.pop("mode", None)  # v1 validators already run after parsing

        def decorate(func):
            target = func.__func__ if isinstance(func, classmethod) else func
            return _V1Validator(*fields, allow_reuse=True, check_fields=False,
                                **kwargs)(target)

        return decorate
