# Plan de direccionamiento e infraestructura - Mesa 2
Idea para el proyecto final

Vamos a montar un mini centro de datos con 5 computadoras virtuales, donde todo se administre solo, se monitoree solo y nos avise en el teléfono si algo falla. Una de las 5 máquinas es la principal, la que manda todo; otra es su copia por si la principal se cae; y las otras 3 hacen el trabajo pesado: una guarda datos, otra se encarga de la telefonía y otra hace respaldos. Así evitamos depender de una sola máquina y el sistema sigue funcionando aunque falle una parte.

## Las 5 máquinas y su función
Nodo-cerebro (la principal): es la que manda todo. Aquí instalamos Salt y Zabbix.
Nodo-backup (copia de la principal): tiene lo mismo que la principal. Si la principal se cae, esta toma el control.
Nodo-datos: guarda los datos del sistema, con una base de datos.
Nodo-voip: es la máquina de telefonía, con Asterisk. Aquí estarán las extensiones 201 y 202 para poder llamar entre ellas.
Nodo-respaldos: es la máquina de respaldos, con UrBackup. Guarda copias de seguridad de las otras máquinas.

*- Herramientas
*- Ubuntu Server 24.04
*- QEMU + KVM
*- Salt
*- Graylog
*- Asterisk
*- UrBackup
*- Git
