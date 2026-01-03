from django.db import models

from rest_server.aggregator.choices import (
    IP_ADDRESS_TYPE_CHOICES,
    UTILIZATION_TYPE_CHOICES,
)


class Host(models.Model):
    name = models.CharField(max_length=255)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now_add=True)

    def __str__(self):
        return self.name


class IPAddress(models.Model):
    host = models.ForeignKey(
        Host, on_delete=models.CASCADE, related_name="ip_addresses"
    )
    type = models.CharField(max_length=50, choices=IP_ADDRESS_TYPE_CHOICES)
    value = models.GenericIPAddressField()
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now_add=True)

    def __str__(self):
        return f"{self.host.name} ({self.value})"


class Storage(models.Model):
    host = models.ForeignKey(Host, on_delete=models.CASCADE, related_name="storages")
    name = models.CharField(max_length=255)
    file_system = models.CharField(max_length=100)
    total_size = models.BigIntegerField()
    used_size = models.BigIntegerField()
    free_size = models.BigIntegerField()
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now_add=True)

    def __str__(self):
        return f"{self.host.name} - {self.name}"


class Temperatue(models.Model):
    host = models.ForeignKey(
        Host, on_delete=models.CASCADE, related_name="temperatures"
    )
    sensor_name = models.CharField(max_length=255)
    value = models.FloatField()
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now_add=True)

    def __str__(self):
        return f"{self.host.name} - {self.sensor_name}: {self.value}°C"


class Utilization(models.Model):
    host = models.ForeignKey(
        Host, on_delete=models.CASCADE, related_name="utilizations"
    )
    type = models.CharField(max_length=50, choices=UTILIZATION_TYPE_CHOICES)
    value = models.FloatField()

    def __str__(self):
        return f"{self.host.name} - {self.type}: {self.value}"
