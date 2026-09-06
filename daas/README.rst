==========
daas chart
==========

The Docker Engine API gateway (`openstack-daas
<https://github.com/fivetime/openstack-daas>`_), as OpenStack-Helm
deploys it.

One process, three listeners
----------------------------

===========  ======  ==================================================
Port         Auth    Who reaches it
===========  ======  ==================================================
2376         client  the tenant's docker CLI (TLS, certificate checked
             cert    in this process -- nothing in front may terminate
                     that handshake, so the Service is layer 4)
2222         SSH     the same client over ``ssh://``
             key
9518         token   the dashboard, and any tenant who has no
                     certificate yet. Plain HTTP: the route in front
                     holds the certificate for the name a browser types
===========  ======  ==================================================

Only the self-service API is registered in the keystone catalog (service
type ``daas``). The Engine API speaks Docker's protocol, and an
OpenStack client that discovered it there would try to speak OpenStack
to it.

What this chart does not own
----------------------------

``daas.conf`` and the tenant CA. Both hold secrets that outlive any
release -- a database password, a service credential, and the CA private
key every tenant certificate is signed with -- so they live in secrets
made outside the chart (``secrets.config.gateway``,
``secrets.tls.gateway``) and this only mounts them. ``conf.rendered:
true`` is for a fresh install whose values already carry them.

⚠️ Two things learned installing it
-----------------------------------

* **fsGroup is not optional.** The CA key is mounted 0400, owned by
  root, and the process is not root. Without ``pod.security_context``
  every pod crashes at start with ``PermissionError`` from
  ``load_cert_chain`` -- which reads like a broken image.

* **The Service selects on two labels, not the full set.**
  ``kubernetes_metadata_labels`` includes ``release_group``, and a
  selector carrying it drops every endpoint the moment a Deployment is
  replaced -- exactly when the connections it holds (a ``logs -f``, a
  running build) must not be cut.

Adopting an existing deployment
-------------------------------

A Deployment created by ``kubectl apply`` can be taken over, but its
``spec.selector`` is immutable and will not match this chart's. Detach
it first, keeping the pods serving::

    kubectl -n openstack annotate deploy,svc daas-gateway \
        meta.helm.sh/release-name=daas \
        meta.helm.sh/release-namespace=openstack --overwrite
    kubectl -n openstack label deploy,svc daas-gateway \
        app.kubernetes.io/managed-by=Helm --overwrite
    kubectl -n openstack delete deploy daas-gateway --cascade=orphan
    helm upgrade --install daas ./daas -n openstack -f <overrides>

Then, once the new pods are ready, delete the orphaned ReplicaSet --
**not just its pods**: an orphaned ReplicaSet still has a controller and
recreates them.
